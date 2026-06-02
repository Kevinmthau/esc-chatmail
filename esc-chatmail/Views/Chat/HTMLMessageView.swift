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
    case unavailable

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
    private let maxAutoRetryAttempts: Int
    private let autoRetryDelay: TimeInterval
    private let autoRetryTimeout: TimeInterval
    private var activeBaseLoadKey: String?
    private var activeLoadTaskKey: String?

    init(
        originalEmailSourceLoader: any OriginalEmailSourceLoading = OriginalEmailSourceLoader.shared,
        loadTimeout: TimeInterval = 5.0,
        recoveringDelay: TimeInterval = 5.0,
        maxAutoRetryAttempts: Int = 1,
        autoRetryDelay: TimeInterval = 0.5,
        autoRetryTimeout: TimeInterval = 1.0
    ) {
        self.originalEmailSourceLoader = originalEmailSourceLoader
        self.loadTimeout = loadTimeout
        self.recoveringDelay = recoveringDelay
        self.maxAutoRetryAttempts = max(0, maxAutoRetryAttempts)
        self.autoRetryDelay = max(0, autoRetryDelay)
        self.autoRetryTimeout = max(0, autoRetryTimeout)
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

        var source = await loadSource(
            for: request,
            timeout: loadTimeout
        )

        guard !Task.isCancelled,
              activeLoadTaskKey == taskLoadKey else {
            return nil
        }

        if source == nil, !shouldPreserveLoadedContent {
            source = await retryMissingSourceIfNeeded(
                for: request,
                taskLoadKey: taskLoadKey,
                recoveryPolicy: missingSourceRecoveryPolicy
            )
        }

        guard !Task.isCancelled,
              activeLoadTaskKey == taskLoadKey else {
            return nil
        }

        if let source {
            activeHTMLSourceSignature = source.sourceSignature
            applyLoadedSource(source)
        } else if !shouldPreserveLoadedContent {
            switch missingSourceRecoveryPolicy {
            case .markUnavailableAfterRetries:
                activeHTMLSourceSignature = nil
                loadState = .unavailable
            case .keepRecoveringWhileActive:
                markRecoveringIfCurrent(taskLoadKey: taskLoadKey)
            }
        }
        return source
    }

    func retry() {
        loadState = .loading
        reloadGeneration &+= 1
    }

    func reloadPreservingContent() {
        reloadGeneration &+= 1
    }

    private func loadSource(
        for request: OriginalEmailLoadRequest,
        timeout: TimeInterval
    ) async -> OriginalEmailSource? {
        await originalEmailSourceLoader.loadOriginalEmailSource(
            messageId: request.messageId,
            bodyStorageURI: request.bodyStorageURI,
            bodyText: request.bodyText,
            senderEmail: request.senderEmail,
            subject: request.subject,
            timeout: timeout
        )
    }

    private func retryMissingSourceIfNeeded(
        for request: OriginalEmailLoadRequest,
        taskLoadKey: String,
        recoveryPolicy: OriginalEmailMissingSourceRecoveryPolicy
    ) async -> OriginalEmailSource? {
        switch recoveryPolicy {
        case .markUnavailableAfterRetries:
            return await autoRetryMissingSourceIfNeeded(
                for: request,
                taskLoadKey: taskLoadKey
            )
        case .keepRecoveringWhileActive:
            return await keepRecoveringWhileActive(
                for: request,
                taskLoadKey: taskLoadKey
            )
        }
    }

    private func autoRetryMissingSourceIfNeeded(
        for request: OriginalEmailLoadRequest,
        taskLoadKey: String
    ) async -> OriginalEmailSource? {
        guard maxAutoRetryAttempts > 0 else {
            return nil
        }

        if case .loading = loadState {
            loadState = .recovering
        }

        for _ in 0..<maxAutoRetryAttempts {
            guard !Task.isCancelled,
                  activeLoadTaskKey == taskLoadKey else {
                return nil
            }

            let retryDelayNanoseconds = UInt64(autoRetryDelay * 1_000_000_000)
            if retryDelayNanoseconds > 0 {
                try? await Task.sleep(nanoseconds: retryDelayNanoseconds)
            }

            guard !Task.isCancelled,
                  activeLoadTaskKey == taskLoadKey else {
                return nil
            }

            if let source = await loadSource(
                for: request,
                timeout: autoRetryTimeout
            ) {
                return source
            }
        }

        return nil
    }

    private func keepRecoveringWhileActive(
        for request: OriginalEmailLoadRequest,
        taskLoadKey: String
    ) async -> OriginalEmailSource? {
        markRecoveringIfCurrent(taskLoadKey: taskLoadKey)

        while !Task.isCancelled,
              activeLoadTaskKey == taskLoadKey {
            let idleDelay = autoRetryDelay > 0 ? autoRetryDelay : 1.0
            try? await Task.sleep(nanoseconds: UInt64(idleDelay * 1_000_000_000))

            guard !Task.isCancelled,
                  activeLoadTaskKey == taskLoadKey else {
                return nil
            }

            if let source = await loadSource(
                for: request,
                timeout: autoRetryTimeout
            ) {
                return source
            }

            markRecoveringIfCurrent(taskLoadKey: taskLoadKey)
        }

        return nil
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
                loadState = .unavailable
            }
        case .nativePlainText:
            if let plainText = source.plainText {
                loadState = .loaded(.plainText(plainText))
            } else {
                loadState = .unavailable
            }
        }
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
                recoveringDelay: recoveringDelay
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
        case .unavailable:
            unavailableContent
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
    private var unavailableContent: some View {
        if let snapshotPlaceholder {
            // Never dead-end on a blank "Unavailable" card when the rendered preview is still on hand.
            snapshotPlaceholderView(snapshotPlaceholder)
                .overlay(alignment: .bottom) {
                    Button {
                        loadViewModel.retry()
                    } label: {
                        SwiftUI.Label("Reload full email", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.borderedProminent)
                    .padding(.bottom, 20)
                }
        } else {
            ContentUnavailableView {
                SwiftUI.Label("Original Email Unavailable", systemImage: "doc.text")
            } description: {
                Text("The original email content could not be loaded. Recovery may still finish in the background.")
            } actions: {
                Button("Retry") {
                    loadViewModel.retry()
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
            missingSourceRecoveryPolicy: snapshotPlaceholder == nil
                ? .markUnavailableAfterRetries
                : .keepRecoveringWhileActive
        )

        guard !Task.isCancelled else {
            return
        }

        // If we loaded HTML from the per-message file location (or recovered/saved it there),
        // ensure Core Data points at the canonical file URL so the rest of the UI can treat it as
        // having a stable HTML source.
        if source?.shouldPointBodyStorageURIAtMessageFile == true,
           let context = message.managedObjectContext {
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

        if let source {
            Log.diagnostic(
                .htmlPreview,
                level: .info,
                "HTMLMessageView loaded message \(message.id) sourceKind=\(source.sourceKind.rawValue) sourceLocation=\(source.sourceLocation.rawValue) presentation=\(source.presentation.rawValue) hasHTML=\(source.html != nil)",
                category: .ui
            )
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
        guard let changedMessageId = notification.userInfo?[HTMLContentLoader.contentSourceDidChangeMessageIdUserInfoKey] as? String,
              changedMessageId == message.id else {
            return
        }

        let changedSourceSignature = notification.userInfo?[HTMLContentLoader.contentSourceDidChangeSourceSignatureUserInfoKey] as? String
        if let changedSourceSignature,
           changedSourceSignature == loadViewModel.activeHTMLSourceSignature {
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
