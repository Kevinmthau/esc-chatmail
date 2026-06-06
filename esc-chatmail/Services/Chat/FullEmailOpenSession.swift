import Foundation
import CoreData
import Combine

struct FullEmailPlaceholder: Equatable, Sendable {
    static let previewCharacterLimit = 500
    static let bodyTextPreviewScanLimit = 4_000
    private static let normalizationWhitespace = CharacterSet.whitespacesAndNewlines

    let messageId: String
    let subject: String
    let senderName: String?
    let senderEmail: String?
    let previewText: String?
    let date: Date?

    var senderDisplayText: String {
        senderName ?? senderEmail ?? "Unknown Sender"
    }

    init(message: Message) {
        self.messageId = message.id
        self.subject = Self.normalizedSingleLine(message.subject) ?? "No Subject"
        self.senderName = Self.normalizedSingleLine(message.senderNameValue)
        self.senderEmail = Self.normalizedSingleLine(message.senderEmailValue)
        self.previewText = Self.previewText(for: message)
        self.date = message.internalDate
    }

    init(metadata: EmailMetadataSnapshot) {
        self.messageId = metadata.messageId
        self.subject = metadata.subject
        self.senderName = metadata.senderName
        self.senderEmail = metadata.senderEmail
        self.previewText = metadata.previewText
        self.date = metadata.date
    }

    private static func previewText(for message: Message) -> String? {
        if let previewText = normalizedPreviewText(message.chatPreviewTextValue) {
            return previewText
        }
        if let cleanedSnippet = normalizedPreviewText(message.cleanedSnippet) {
            return cleanedSnippet
        }
        if let snippet = normalizedPreviewText(message.snippet) {
            return snippet
        }

        return normalizedBodyPreviewText(message.bodyTextValue)
    }

    private static func normalizedSingleLine(_ value: String?) -> String? {
        normalizedText(value, maxLength: 160)
    }

    private static func normalizedPreviewText(_ value: String?) -> String? {
        normalizedText(value, maxLength: previewCharacterLimit)
    }

    private static func normalizedBodyPreviewText(_ value: String?) -> String? {
        normalizedText(
            value,
            maxLength: previewCharacterLimit,
            scanLimit: bodyTextPreviewScanLimit
        )
    }

    static func normalizedText(_ value: String?, maxLength: Int, scanLimit: Int? = nil) -> String? {
        guard let value else { return nil }
        var result = ""
        result.reserveCapacity(maxLength)
        var pendingWhitespace = false
        var scannedCharacters = 0

        for character in value {
            if let scanLimit, scannedCharacters >= scanLimit {
                break
            }
            scannedCharacters += 1

            if isWhitespaceOrNewline(character) {
                if !result.isEmpty {
                    pendingWhitespace = true
                }
                continue
            }

            if pendingWhitespace {
                guard result.count < maxLength else { break }
                result.append(" ")
                pendingWhitespace = false
            }

            guard result.count < maxLength else { break }
            result.append(character)
        }

        let collapsed = result.trimmingCharacters(in: .whitespacesAndNewlines)
        return collapsed.isEmpty ? nil : collapsed
    }

    private static func isWhitespaceOrNewline(_ character: Character) -> Bool {
        character.unicodeScalars.allSatisfy { normalizationWhitespace.contains($0) }
    }
}

enum FullEmailReaderState: Equatable {
    case preparedArtifact(EmailReaderArtifact, placeholder: FullEmailPlaceholder)
    case loading(FullEmailPlaceholder)
    case recovering(FullEmailPlaceholder)
    case loadedArtifact(EmailReaderArtifact, placeholder: FullEmailPlaceholder)
    case retryableFailure(FullEmailPlaceholder, reason: String)
    case unrecoverableFailure(FullEmailPlaceholder, reason: String)

    var hasLoadedContent: Bool {
        switch self {
        case .preparedArtifact, .loadedArtifact:
            return true
        case .loading, .recovering, .retryableFailure, .unrecoverableFailure:
            return false
        }
    }

    var artifact: EmailReaderArtifact? {
        switch self {
        case .preparedArtifact(let artifact, placeholder: _),
             .loadedArtifact(let artifact, placeholder: _):
            return artifact
        case .loading, .recovering, .retryableFailure, .unrecoverableFailure:
            return nil
        }
    }
}

enum OriginalEmailMissingSourceRecoveryPolicy: Sendable {
    case markUnavailableAfterRetries
    case keepRecoveringWhileActive
}

private enum OriginalEmailTimedLoadResult {
    case completed(OriginalEmailSource?)
    case timedOut
}

private struct PrepaintedReaderArtifactWidthKey: Hashable {
    let sourceSignature: String
    let renderSignature: String
    let widthBucket: Int
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
            StableFingerprint.sha256Prefix(bodyText),
            StableFingerprint.sha256Prefix(subject),
            StableFingerprint.sha256Prefix(senderEmail)
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

enum OriginalEmailContentSourceReloadPolicy {
    static func shouldReload(
        changedMessageId: String?,
        currentMessageId: String,
        changedSourceSignature: String?,
        activeSourceSignature: String?,
        readerState: FullEmailReaderState
    ) -> Bool {
        guard changedMessageId == currentMessageId else {
            return false
        }

        if let changedSourceSignature,
           changedSourceSignature == activeSourceSignature {
            return false
        }

        switch readerState {
        case .preparedArtifact, .loading, .recovering, .loadedArtifact, .retryableFailure, .unrecoverableFailure:
            return true
        }
    }
}

@MainActor
final class FullEmailOpenSession: ObservableObject, Identifiable {
    let id: NSManagedObjectID
    let messageId: String
    let messageObjectID: NSManagedObjectID
    let message: Message
    let request: OriginalEmailWarmRequest
    let initialArtifact: EmailReaderArtifact?
    let immediatePlaceholder: FullEmailPlaceholder
    let webViewAdoptionProvider: (any FullEmailWebViewAdopting)?

    @Published private(set) var readerState: FullEmailReaderState
    @Published private(set) var loadingGeneration = 0
    private(set) var activeHTMLSourceSignature: String?

    private let originalEmailSourceLoader: any OriginalEmailSourceLoading
    private let loadTimeout: TimeInterval
    private let recoveringDelay: TimeInterval
    private let fullEmailOpener: (any FullEmailOpening)?
    private let onSourceLoaded: @MainActor (Message, OriginalEmailSource) -> Void
    private var activeBaseLoadKey: String?
    private var activeLoadTaskKey: String?
    private var timedOutSourceObservationTask: Task<Void, Never>?
    private var readerStartLogged = false
    private var prepaintedArtifactWidthKeys: Set<PrepaintedReaderArtifactWidthKey> = []

    var hasImmediateVisualSurface: Bool {
        initialArtifact != nil || !immediatePlaceholder.subject.isEmpty
    }

    var loadRequest: OriginalEmailLoadRequest {
        OriginalEmailLoadRequest(
            messageId: message.id,
            bodyStorageURI: message.bodyStorageURI,
            bodyText: message.bodyText,
            subject: message.subject,
            senderEmail: message.senderEmail
        )
    }

    var loadKey: String {
        loadTaskKey(for: loadRequest)
    }

    init(
        message: Message,
        request: OriginalEmailWarmRequest,
        initialArtifact: EmailReaderArtifact?,
        immediatePlaceholder: FullEmailPlaceholder,
        fullEmailOpener: (any FullEmailOpening)? = nil,
        originalEmailSourceLoader: any OriginalEmailSourceLoading = OriginalEmailSourceLoader.shared,
        originalEmailLoadTimeout: TimeInterval = 5.0,
        recoveringDelay: TimeInterval = 5.0,
        onSourceLoaded: (@MainActor (Message, OriginalEmailSource) -> Void)? = nil
    ) {
        let validInitialArtifact = initialArtifact?.messageID == message.id ? initialArtifact : nil
        let initialRequest = OriginalEmailLoadRequest(
            messageId: message.id,
            bodyStorageURI: message.bodyStorageURI,
            bodyText: message.bodyText,
            subject: message.subject,
            senderEmail: message.senderEmail
        )

        self.id = message.objectID
        self.messageId = message.id
        self.messageObjectID = message.objectID
        self.message = message
        self.request = request
        self.initialArtifact = validInitialArtifact
        self.immediatePlaceholder = immediatePlaceholder
        self.webViewAdoptionProvider = fullEmailOpener as? any FullEmailWebViewAdopting
        self.fullEmailOpener = fullEmailOpener
        self.originalEmailSourceLoader = originalEmailSourceLoader
        self.loadTimeout = originalEmailLoadTimeout
        self.recoveringDelay = recoveringDelay
        self.onSourceLoaded = onSourceLoaded ?? { message, source in
            Self.updateBodyStorageURIIfNeeded(for: message, source: source)
        }

        if let validInitialArtifact {
            self.readerState = .preparedArtifact(validInitialArtifact, placeholder: immediatePlaceholder)
            self.activeHTMLSourceSignature = validInitialArtifact.sourceSignature
            self.activeBaseLoadKey = initialRequest.identity.baseLoadKey
            self.activeLoadTaskKey = "\(initialRequest.identity.baseLoadKey)|reload:0"
        } else {
            self.readerState = .loading(immediatePlaceholder)
            self.activeHTMLSourceSignature = nil
            self.activeBaseLoadKey = nil
            self.activeLoadTaskKey = nil
        }
    }

    deinit {
        timedOutSourceObservationTask?.cancel()
    }

    @discardableResult
    func loadReaderContent() async -> OriginalEmailSource? {
        Log.diagnostic(.htmlPreview, level: .info, "FullEmailOpenSession loading message \(message.id)", category: .ui)
        if initialArtifact != nil {
            logReaderStartIfNeeded(mode: "prepared_html")
        }

        let source = await loadOriginalEmail(
            for: loadRequest,
            missingSourceRecoveryPolicy: .keepRecoveringWhileActive
        )

        guard !Task.isCancelled else {
            return source
        }

        if let source {
            if initialArtifact == nil {
                logReaderStartIfNeeded(
                    mode: source.sourceLocation == .recoveredHTML ? "recovery" : "live_load"
                )
            }
            Log.diagnostic(
                .htmlPreview,
                level: .info,
                "FullEmailOpenSession loaded message \(message.id) sourceKind=\(source.sourceKind.rawValue) sourceLocation=\(source.sourceLocation.rawValue) presentation=\(source.presentation.rawValue) hasHTML=\(source.html != nil)",
                category: .ui
            )
        } else if initialArtifact == nil {
            logReaderStartIfNeeded(mode: "live_load")
        }

        return source
    }

    func prepareForMeasuredReaderWidth(_ width: CGFloat) {
        guard width > 1 else {
            return
        }

        guard let artifact = readerState.artifact else {
            fullEmailOpener?.prewarmOnOpen(message: message, width: width)
            return
        }

        guard case .html = artifact.body else {
            return
        }

        let prepaintKey = PrepaintedReaderArtifactWidthKey(
            sourceSignature: artifact.sourceSignature,
            renderSignature: artifact.renderSignature,
            widthBucket: Int(width.rounded())
        )
        guard prepaintedArtifactWidthKeys.insert(prepaintKey).inserted else {
            return
        }

        fullEmailOpener?.prepaintAfterExplicitOpen(
            request: request,
            message: message,
            artifact: artifact,
            width: width
        )
    }

    @discardableResult
    func loadOriginalEmail(
        for request: OriginalEmailLoadRequest,
        missingSourceRecoveryPolicy: OriginalEmailMissingSourceRecoveryPolicy = .markUnavailableAfterRetries
    ) async -> OriginalEmailSource? {
        let taskBaseLoadKey = request.identity.baseLoadKey
        let taskLoadKey = loadTaskKey(for: request)
        let shouldReset = activeBaseLoadKey != taskBaseLoadKey
        let shouldPreserveLoadedContent = !shouldReset && readerState.hasLoadedContent
        activeBaseLoadKey = taskBaseLoadKey
        activeLoadTaskKey = taskLoadKey
        // A new load supersedes any pending late-source observer from a prior load.
        timedOutSourceObservationTask?.cancel()
        if shouldReset {
            activeHTMLSourceSignature = nil
        }

        if shouldReset || !readerState.hasLoadedContent {
            readerState = .loading(immediatePlaceholder)
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
                readerState = .retryableFailure(immediatePlaceholder, reason: "original_email_unavailable")
            case .keepRecoveringWhileActive:
                readerState = .retryableFailure(immediatePlaceholder, reason: "original_email_unavailable")
            }
        }
        return source
    }

    func retry() {
        readerState = .loading(immediatePlaceholder)
        loadingGeneration &+= 1
    }

    func reloadPreservingContent() {
        loadingGeneration &+= 1
    }

    func reloadIfRemoteImageFallbackWarmed(_ notification: Notification) {
        guard let warmedMessageId = notification.userInfo?[HTMLContentLoader.remoteImageAttachmentFallbackMessageIdUserInfoKey] as? String,
              warmedMessageId == message.id else {
            return
        }

        reloadPreservingContent()
    }

    func reloadIfContentSourceChanged(_ notification: Notification) {
        let changedMessageId = notification.userInfo?[HTMLContentLoader.contentSourceDidChangeMessageIdUserInfoKey] as? String
        let changedSourceSignature = notification.userInfo?[HTMLContentLoader.contentSourceDidChangeSourceSignatureUserInfoKey] as? String
        guard OriginalEmailContentSourceReloadPolicy.shouldReload(
            changedMessageId: changedMessageId,
            currentMessageId: message.id,
            changedSourceSignature: changedSourceSignature,
            activeSourceSignature: activeHTMLSourceSignature,
            readerState: readerState
        ) else {
            return
        }

        reloadPreservingContent()
    }

    private func loadTaskKey(for request: OriginalEmailLoadRequest) -> String {
        "\(request.identity.baseLoadKey)|reload:\(loadingGeneration)"
    }

    private func observeTimedOutSource(
        _ sourceTask: Task<OriginalEmailSource?, Never>,
        taskLoadKey: String
    ) {
        timedOutSourceObservationTask?.cancel()
        timedOutSourceObservationTask = Task { [weak self] in
            let source = await sourceTask.value
            // The class is @MainActor, so we resume on the main actor here. Bail if a
            // newer load superseded/cancelled this observer (or the session went
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
        if case .loading = readerState {
            readerState = .recovering(immediatePlaceholder)
        }
    }

    private func applyLoadedSource(_ source: OriginalEmailSource) {
        guard let artifact = EmailReaderArtifact.make(
            messageID: message.id,
            source: source,
            metadata: EmailMetadataSnapshot(placeholder: immediatePlaceholder),
            message: message
        ) else {
            switch source.presentation {
            case .html:
                readerState = .unrecoverableFailure(immediatePlaceholder, reason: "missing_html_payload")
            case .nativePlainText:
                readerState = .unrecoverableFailure(immediatePlaceholder, reason: "missing_plain_text_payload")
            }
            return
        }

        readerState = .loadedArtifact(artifact, placeholder: immediatePlaceholder)
    }

    private func acceptLoadedSource(_ source: OriginalEmailSource) {
        activeHTMLSourceSignature = source.sourceSignature
        applyLoadedSource(source)
        onSourceLoaded(message, source)
    }

    private func logReaderStartIfNeeded(mode: String) {
        guard !readerStartLogged else {
            return
        }

        readerStartLogged = true
        OriginalEmailTelemetry.log(
            event: "reader_started",
            messageId: message.id,
            detail: "mode=\(mode)"
        )
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
        let messageObjectID = message.objectID
        Task {
            await context.perform {
                guard let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
                    return
                }
                guard let resolvedObject = try? context.existingObject(with: messageObjectID),
                      let message = resolvedObject as? Message,
                      !message.isDeleted else {
                    return
                }
                let messagesDirectory = documentsPath.appendingPathComponent("Messages")
                let fileURL = messagesDirectory.appendingPathComponent("\(messageId).html")
                message.bodyStorageURI = fileURL.absoluteString
                context.saveOrLog(operation: "update message body storage URI")
            }
        }
    }
}
