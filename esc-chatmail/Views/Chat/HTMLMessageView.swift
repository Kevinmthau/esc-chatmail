import SwiftUI
import UIKit

// MARK: - Full HTML Message View
enum OriginalEmailLoadedContent: Equatable {
    case html(String)
    case plainText(String)
}

enum OriginalEmailLoadState: Equatable {
    case loading
    case recovering
    case loaded(OriginalEmailLoadedContent)
    case retryableFailure(String)
    case unrecoverableFailure(String)

    var hasLoadedContent: Bool {
        if case .loaded = self {
            return true
        }
        return false
    }
}

enum OriginalEmailMissingSourceRecoveryPolicy: Sendable {
    case markUnavailableAfterRetries
    case keepRecoveringWhileActive
}

enum OriginalEmailContentSourceReloadPolicy {
    static func shouldReload(
        changedMessageId: String?,
        currentMessageId: String,
        changedSourceSignature: String?,
        activeSourceSignature: String?,
        loadState: OriginalEmailLoadState
    ) -> Bool {
        guard changedMessageId == currentMessageId else {
            return false
        }

        if let changedSourceSignature,
           changedSourceSignature == activeSourceSignature {
            return false
        }

        switch loadState {
        case .loading, .recovering, .loaded, .retryableFailure, .unrecoverableFailure:
            return true
        }
    }
}

private enum OriginalEmailTimedLoadResult {
    case completed(OriginalEmailSource?)
    case timedOut
}

struct OriginalEmailLoadIdentity: Equatable, Sendable {
    let baseLoadKey: String

    static func make(
        messageId: String,
        bodyStorageURI: String?,
        bodyText: String?,
        subject: String?,
        senderEmail: String?
    ) -> OriginalEmailLoadIdentity {
        let baseLoadKey = [
            messageId,
            bodyStorageURI ?? "",
            "\(bodyText?.hashValue ?? 0)",
            "\(subject?.hashValue ?? 0)",
            "\(senderEmail?.hashValue ?? 0)"
        ].joined(separator: "|")

        return OriginalEmailLoadIdentity(baseLoadKey: baseLoadKey)
    }
}

struct OriginalEmailLoadRequest: Equatable, Sendable {
    let messageId: String
    let bodyStorageURI: String?
    let bodyText: String?
    let subject: String?
    let senderEmail: String?
    let identity: OriginalEmailLoadIdentity

    init(
        messageId: String,
        bodyStorageURI: String?,
        bodyText: String?,
        subject: String?,
        senderEmail: String?
    ) {
        self.messageId = messageId
        self.bodyStorageURI = bodyStorageURI
        self.bodyText = bodyText
        self.subject = subject
        self.senderEmail = senderEmail
        self.identity = OriginalEmailLoadIdentity.make(
            messageId: messageId,
            bodyStorageURI: bodyStorageURI,
            bodyText: bodyText,
            subject: subject,
            senderEmail: senderEmail
        )
    }
}

@MainActor
final class OriginalEmailLoadViewModel: ObservableObject {
    @Published private(set) var loadState: OriginalEmailLoadState = .loading
    @Published private(set) var reloadGeneration = 0
    private(set) var activeHTMLSourceSignature: String?

    private let originalEmailSourceLoader: any OriginalEmailSourceLoading
    private let loadTimeout: TimeInterval
    private let recoveringDelay: TimeInterval
    private let onSourceLoaded: @MainActor (OriginalEmailSource) -> Void
    private var activeBaseLoadKey: String?
    private var activeLoadTaskKey: String?
    private var timedOutSourceObservationTask: Task<Void, Never>?

    init(
        originalEmailSourceLoader: any OriginalEmailSourceLoading = OriginalEmailSourceLoader.shared,
        loadTimeout: TimeInterval = 5.0,
        recoveringDelay: TimeInterval = 5.0,
        onSourceLoaded: @escaping @MainActor (OriginalEmailSource) -> Void = { _ in }
    ) {
        self.originalEmailSourceLoader = originalEmailSourceLoader
        self.loadTimeout = loadTimeout
        self.recoveringDelay = recoveringDelay
        self.onSourceLoaded = onSourceLoaded
    }

    func loadOriginalEmail(
        for request: OriginalEmailLoadRequest,
        missingSourceRecoveryPolicy: OriginalEmailMissingSourceRecoveryPolicy = .markUnavailableAfterRetries
    ) async -> OriginalEmailSource? {
        let taskBaseLoadKey = request.identity.baseLoadKey
        let taskLoadKey = "\(taskBaseLoadKey)|reload:\(reloadGeneration)"
        let shouldReset = activeBaseLoadKey != taskBaseLoadKey
        let shouldPreserveLoadedContent = !shouldReset && loadState.hasLoadedContent
        activeBaseLoadKey = taskBaseLoadKey
        activeLoadTaskKey = taskLoadKey
        // A new load supersedes any pending late-source observer from a prior load.
        timedOutSourceObservationTask?.cancel()
        if shouldReset {
            activeHTMLSourceSignature = nil
        }

        if shouldReset || !loadState.hasLoadedContent {
            loadState = .loading
        }

        let recoveringTask = Task { [weak self] in
            let nanoseconds = UInt64(max(0, self?.recoveringDelay ?? 0) * 1_000_000_000)
            try? await Task.sleep(nanoseconds: nanoseconds)
            guard !Task.isCancelled else {
                return
            }
            self?.markRecoveringIfCurrent(taskLoadKey: taskLoadKey)
        }
        defer { recoveringTask.cancel() }

        let sourceTask = ensureSourceTask(for: request)
        let timedLoadResult = await ensureSource(
            from: sourceTask,
            timeout: loadTimeout
        )

        guard !Task.isCancelled,
              activeLoadTaskKey == taskLoadKey else {
            return nil
        }

        var source: OriginalEmailSource?
        switch timedLoadResult {
        case .completed(let completedSource):
            source = completedSource
        case .timedOut:
            if !shouldPreserveLoadedContent,
               missingSourceRecoveryPolicy == .keepRecoveringWhileActive {
                markRecoveringIfCurrent(taskLoadKey: taskLoadKey)
                source = await waitForSourceWhileActive(sourceTask)

                guard !Task.isCancelled,
                      activeLoadTaskKey == taskLoadKey else {
                    return nil
                }
            } else if !shouldPreserveLoadedContent {
                observeTimedOutSource(sourceTask, taskLoadKey: taskLoadKey)
            }
        }

        if let source {
            acceptLoadedSource(source)
        } else if !shouldPreserveLoadedContent {
            switch missingSourceRecoveryPolicy {
            case .markUnavailableAfterRetries:
                activeHTMLSourceSignature = nil
                loadState = .retryableFailure("original_email_unavailable")
            case .keepRecoveringWhileActive:
                loadState = .retryableFailure("original_email_unavailable")
            }
        }
        return source
    }

    private func observeTimedOutSource(
        _ sourceTask: Task<OriginalEmailSource?, Never>,
        taskLoadKey: String
    ) {
        timedOutSourceObservationTask?.cancel()
        timedOutSourceObservationTask = Task { [weak self] in
            let source = await sourceTask.value
            // The class is @MainActor, so we resume on the main actor here. Bail if a
            // newer load superseded/cancelled this observer (or the view model went
            // away) before the timed-out source finally resolved.
            guard !Task.isCancelled, let self, let source else {
                return
            }
            self.applyTimedOutSourceIfCurrent(source, taskLoadKey: taskLoadKey)
        }
    }

    private func applyTimedOutSourceIfCurrent(_ source: OriginalEmailSource, taskLoadKey: String) {
        guard activeLoadTaskKey == taskLoadKey else {
            return
        }

        acceptLoadedSource(source)
    }

    func retry() {
        loadState = .loading
        reloadGeneration &+= 1
    }

    func reloadPreservingContent() {
        reloadGeneration &+= 1
    }

    private func ensureSourceTask(for request: OriginalEmailLoadRequest) -> Task<OriginalEmailSource?, Never> {
        let loader = self.originalEmailSourceLoader
        return Task(priority: .userInitiated) {
            await loader.ensureOriginalEmailAvailable(
                messageId: request.messageId,
                bodyStorageURI: request.bodyStorageURI,
                bodyText: request.bodyText,
                senderEmail: request.senderEmail,
                subject: request.subject
            )
        }
    }

    private func ensureSource(
        from task: Task<OriginalEmailSource?, Never>,
        timeout: TimeInterval
    ) async -> OriginalEmailTimedLoadResult {
        let result: OriginalEmailSource?? = await withSoftTimeout(seconds: timeout) {
            await task.value
        }
        guard let result else {
            return .timedOut
        }
        return .completed(result)
    }

    private func waitForSourceWhileActive(_ sourceTask: Task<OriginalEmailSource?, Never>) async -> OriginalEmailSource? {
        await awaitValueUnlessCancelled(of: sourceTask, cancellationValue: nil)
    }

    private func markRecoveringIfCurrent(taskLoadKey: String) {
        guard activeLoadTaskKey == taskLoadKey else {
            return
        }
        if case .loading = loadState {
            loadState = .recovering
        }
    }

    private func applyLoadedSource(_ source: OriginalEmailSource) {
        switch source.presentation {
        case .html:
            if let html = source.html {
                loadState = .loaded(.html(html))
            } else {
                loadState = .unrecoverableFailure("missing_html_payload")
            }
        case .nativePlainText:
            if let plainText = source.plainText {
                loadState = .loaded(.plainText(plainText))
            } else {
                loadState = .unrecoverableFailure("missing_plain_text_payload")
            }
        }
    }

    private func acceptLoadedSource(_ source: OriginalEmailSource) {
        activeHTMLSourceSignature = source.sourceSignature
        applyLoadedSource(source)
        onSourceLoaded(source)
    }
}

struct HTMLMessageView: View {
    let message: Message
    @Environment(\.dismiss) private var dismiss
    @StateObject private var loadViewModel: OriginalEmailLoadViewModel
    /// The already-rendered chat preview snapshot, shown instantly while the live WebView paints.
    @State private var snapshotPlaceholder: UIImage?
    /// Set once the live WebView reports its first paint, cross-fading the snapshot away.
    @State private var webViewPainted = false
    @State private var loadedContentSignature: String?

    init(
        message: Message,
        originalEmailSourceLoader: any OriginalEmailSourceLoading = OriginalEmailSourceLoader.shared,
        originalEmailLoadTimeout: TimeInterval = 5.0,
        recoveringDelay: TimeInterval = 5.0
    ) {
        self.message = message
        self._loadViewModel = StateObject(
            wrappedValue: OriginalEmailLoadViewModel(
                originalEmailSourceLoader: originalEmailSourceLoader,
                loadTimeout: originalEmailLoadTimeout,
                recoveringDelay: recoveringDelay,
                onSourceLoaded: { source in
                    Self.updateBodyStorageURIIfNeeded(for: message, source: source)
                }
            )
        )
    }

    private var loadRequest: OriginalEmailLoadRequest {
        OriginalEmailLoadRequest(
            messageId: message.id,
            bodyStorageURI: message.bodyStorageURI,
            bodyText: message.bodyText,
            subject: message.subject,
            senderEmail: message.senderEmail
        )
    }
    private var loadIdentity: OriginalEmailLoadIdentity {
        loadRequest.identity
    }
    private var baseLoadKey: String {
        loadIdentity.baseLoadKey
    }
    private var loadKey: String {
        "\(baseLoadKey)|reload:\(loadViewModel.reloadGeneration)"
    }

    var body: some View {
        NavigationStack {
            content
            .navigationTitle("Original Email")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: HTMLContentLoader.remoteImageAttachmentFallbackDidWarmNotification)) { notification in
            reloadIfRemoteImageFallbackWarmed(notification)
        }
        .onReceive(NotificationCenter.default.publisher(for: HTMLContentLoader.contentSourceDidChangeNotification)) { notification in
            reloadIfContentSourceChanged(notification)
        }
        .task(id: loadKey) {
            await loadHTMLContent()
        }
        .task(id: message.id) {
            await loadSnapshotPlaceholder()
        }
    }

    @ViewBuilder
    private var content: some View {
        switch loadViewModel.loadState {
        case .loading:
            loadingContent(isRecovering: false)
        case .recovering:
            loadingContent(isRecovering: true)
        case .loaded(let loadedContent):
            switch loadedContent {
            case .html(let html):
                loadedHTMLContent(html: html)
            case .plainText(let text):
                OriginalEmailReadableView(message: message, text: text)
            }
        case .retryableFailure:
            failureContent(allowsRetry: true)
        case .unrecoverableFailure:
            failureContent(allowsRetry: false)
        }
    }

    /// Loading/recovering: if the rendered chat preview snapshot is already available, show it
    /// immediately so the email appears instantly instead of a bare spinner. With cache warming the
    /// load usually resolves within a frame or two; this mainly covers cold/slow opens.
    @ViewBuilder
    private func loadingContent(isRecovering: Bool) -> some View {
        if let snapshotPlaceholder {
            snapshotPlaceholderView(snapshotPlaceholder)
                .overlay(alignment: .bottom) {
                    if isRecovering {
                        loadingBanner(text: "Loading full email…")
                    }
                }
        } else {
            ProgressView(isRecovering ? "Recovering original email..." : "Loading...")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// Loaded HTML: render the interactive WebView, covering its first-paint flash with the snapshot
    /// placeholder and cross-fading the placeholder out once the WebView reports it has painted.
    @ViewBuilder
    private func loadedHTMLContent(html: String) -> some View {
        let contentSignature = loadedHTMLContentSignature(for: html)
        ZStack {
            HTMLWebView(
                htmlContent: html,
                isDarkMode: false,
                message: message,
                onLoadFinished: handleWebViewPainted
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if let snapshotPlaceholder, !webViewPainted {
                snapshotPlaceholderView(snapshotPlaceholder)
                    .transition(.opacity)
                    .allowsHitTesting(false)
            }
        }
        .onAppear {
            handleLoadedContentSignature(contentSignature)
        }
        .onChange(of: contentSignature) { _, newSignature in
            handleLoadedContentSignature(newSignature)
        }
    }

    @ViewBuilder
    private func failureContent(allowsRetry: Bool) -> some View {
        if let snapshotPlaceholder {
            // Never dead-end on a blank "Unavailable" card when the rendered preview is still on hand.
            snapshotPlaceholderView(snapshotPlaceholder)
                .overlay(alignment: .bottom) {
                    if allowsRetry {
                        Button {
                            loadViewModel.retry()
                        } label: {
                            SwiftUI.Label("Reload full email", systemImage: "arrow.clockwise")
                        }
                        .buttonStyle(.borderedProminent)
                        .padding(.bottom, 20)
                    }
                }
        } else {
            ContentUnavailableView {
                SwiftUI.Label("Original Email Unavailable", systemImage: "doc.text")
            } description: {
                Text("The original email content could not be loaded.")
            } actions: {
                if allowsRetry {
                    Button("Retry") {
                        loadViewModel.retry()
                    }
                }
            }
        }
    }

    private func snapshotPlaceholderView(_ image: UIImage) -> some View {
        GeometryReader { geometry in
            Image(uiImage: image)
                .resizable()
                .interpolation(.medium)
                .scaledToFit()
                .frame(width: geometry.size.width, height: geometry.size.height, alignment: .top)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(uiColor: .systemBackground))
    }

    private func loadingBanner(text: String) -> some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial, in: Capsule())
        .padding(.bottom, 20)
    }

    private func handleWebViewPainted() {
        guard !webViewPainted else {
            return
        }
        withAnimation(.easeOut(duration: 0.25)) {
            webViewPainted = true
        }
    }

    private func loadSnapshotPlaceholder() async {
        guard snapshotPlaceholder == nil,
              let metadata = await RenderedMessageCache.shared.latestSnapshotMetadata(messageId: message.id),
              let entry = await EmailPreviewSnapshotCache.shared.load(for: metadata.snapshotCacheKey),
              let image = UIImage(data: entry.imageData),
              !Task.isCancelled else {
            return
        }
        snapshotPlaceholder = image
        if !loadViewModel.loadState.hasLoadedContent {
            loadViewModel.reloadPreservingContent()
        }
    }

    private func loadHTMLContent() async {
        Log.diagnostic(.htmlPreview, level: .info, "HTMLMessageView loading message \(message.id)", category: .ui)
        let source = await loadViewModel.loadOriginalEmail(
            for: loadRequest,
            missingSourceRecoveryPolicy: .keepRecoveringWhileActive
        )

        guard !Task.isCancelled else {
            return
        }

        if let source {
            Log.diagnostic(
                .htmlPreview,
                level: .info,
                "HTMLMessageView loaded message \(message.id) sourceKind=\(source.sourceKind.rawValue) sourceLocation=\(source.sourceLocation.rawValue) presentation=\(source.presentation.rawValue) hasHTML=\(source.html != nil)",
                category: .ui
            )
        }
    }

    private static func updateBodyStorageURIIfNeeded(for message: Message, source: OriginalEmailSource) {
        // If we loaded HTML from the per-message file location (or recovered/saved it there),
        // ensure Core Data points at the canonical file URL so the rest of the UI can treat it as
        // having a stable HTML source.
        guard source.shouldPointBodyStorageURIAtMessageFile,
              let context = message.managedObjectContext else {
            return
        }

        let messageId = message.id
        Task {
            await context.perform {
                guard let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
                    return
                }
                let messagesDirectory = documentsPath.appendingPathComponent("Messages")
                let fileURL = messagesDirectory.appendingPathComponent("\(messageId).html")
                message.bodyStorageURI = fileURL.absoluteString
                context.saveOrLog(operation: "update message body storage URI")
            }
        }
    }

    private func reloadIfRemoteImageFallbackWarmed(_ notification: Notification) {
        guard let warmedMessageId = notification.userInfo?[HTMLContentLoader.remoteImageAttachmentFallbackMessageIdUserInfoKey] as? String,
              warmedMessageId == message.id else {
            return
        }

        loadViewModel.reloadPreservingContent()
    }

    private func reloadIfContentSourceChanged(_ notification: Notification) {
        let changedMessageId = notification.userInfo?[HTMLContentLoader.contentSourceDidChangeMessageIdUserInfoKey] as? String
        let changedSourceSignature = notification.userInfo?[HTMLContentLoader.contentSourceDidChangeSourceSignatureUserInfoKey] as? String
        guard OriginalEmailContentSourceReloadPolicy.shouldReload(
            changedMessageId: changedMessageId,
            currentMessageId: message.id,
            changedSourceSignature: changedSourceSignature,
            activeSourceSignature: loadViewModel.activeHTMLSourceSignature,
            loadState: loadViewModel.loadState
        ) else {
            return
        }

        loadViewModel.reloadPreservingContent()
    }

    private func loadedHTMLContentSignature(for html: String) -> String {
        let htmlSignature = CanonicalEmailContent(
            html: html,
            plainText: nil,
            sourceKind: .html,
            sourceLocation: .messageFile
        ).sourceSignature
        return [
            loadViewModel.activeHTMLSourceSignature ?? "source:nil",
            htmlSignature
        ].joined(separator: "|")
    }

    private func handleLoadedContentSignature(_ signature: String) {
        guard loadedContentSignature != signature else {
            return
        }

        loadedContentSignature = signature
        webViewPainted = false
    }
}

private struct OriginalEmailReadableView: View {
    let message: Message
    let text: String

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                OriginalEmailMetadataCard(message: message)

                Text(Self.linkifiedAttributedString(from: text))
                    .font(.body)
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(18)
                    .background(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(Color(uiColor: .secondarySystemBackground))
                    )
            }
            .padding(16)
        }
        .background(Color(uiColor: .systemBackground))
        .tint(.blue)
    }

    private static func linkifiedAttributedString(from text: String) -> AttributedString {
        let attributed = NSMutableAttributedString(
            string: text,
            attributes: [
                .font: UIFont.preferredFont(forTextStyle: .body),
                .foregroundColor: UIColor.label
            ]
        )

        if let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) {
            let range = NSRange(location: 0, length: attributed.length)
            for match in detector.matches(in: text, options: [], range: range) {
                guard let url = match.url else {
                    continue
                }
                attributed.addAttribute(.link, value: url, range: match.range)
            }
        }

        return AttributedString(attributed)
    }
}

enum OriginalEmailMetadataFormatter {
    static func senderLine(senderName: String?, senderEmail: String?) -> String? {
        let trimmedName = senderName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedEmail = senderEmail?.trimmingCharacters(in: .whitespacesAndNewlines)

        if let trimmedEmail, !trimmedEmail.isEmpty {
            guard let trimmedName, !trimmedName.isEmpty else {
                return trimmedEmail
            }

            if let extractedEmail = EmailNormalizer.extractEmail(from: trimmedName),
               EmailNormalizer.normalize(extractedEmail) == EmailNormalizer.normalize(trimmedEmail) {
                return trimmedName
            }

            if EmailNormalizer.normalize(trimmedName) == EmailNormalizer.normalize(trimmedEmail) {
                return trimmedEmail
            }

            return "\(trimmedName) <\(trimmedEmail)>"
        }

        guard let trimmedName, !trimmedName.isEmpty else {
            return PersonDisplayNameResolver.fallbackSenderName()
        }

        return trimmedName
    }
}

private struct OriginalEmailMetadataCard: View {
    let message: Message

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let subject = message.subject?.trimmingCharacters(in: .whitespacesAndNewlines),
               !subject.isEmpty {
                Text(subject)
                    .font(.headline)
                    .foregroundStyle(.primary)
            }

            if let senderLine, !senderLine.isEmpty {
                Text(senderLine)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Text(message.internalDate.formatted(date: .abbreviated, time: .shortened))
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(uiColor: .secondarySystemBackground))
        )
    }

    private var senderLine: String? {
        OriginalEmailMetadataFormatter.senderLine(
            senderName: message.senderName,
            senderEmail: message.senderEmail
        )
    }
}
