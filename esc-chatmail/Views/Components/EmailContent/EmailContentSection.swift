import SwiftUI
import CoreData
import CryptoKit

struct OriginalEmailWarmRequest: Equatable, Sendable {
    let messageId: String
    let bodyStorageURI: String?
    let bodyText: String?
    let senderEmail: String?
    let subject: String?
}

protocol OriginalEmailSourceWarming: Sendable {
    func warmOriginalEmailSource(request: OriginalEmailWarmRequest) async
}

extension OriginalEmailSourceLoader: OriginalEmailSourceWarming {
    func warmOriginalEmailSource(request: OriginalEmailWarmRequest) async {
        await warmOriginalEmailSource(
            messageId: request.messageId,
            bodyStorageURI: request.bodyStorageURI,
            bodyText: request.bodyText,
            senderEmail: request.senderEmail,
            subject: request.subject
        )
    }
}

/// Container view that routes chat previews by content type.
/// Newsletter and strongly-structured transactional emails render as derived native cards.
/// Other rich HTML renders through a cached snapshot preview, with MiniEmailWebView as failure fallback.
struct EmailContentSection: View {
    let message: ChatMessageRowModel
    let onOpenFullMessage: (EmailReaderOpenSource) -> Void

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.managedObjectContext) private var viewContext
    @State private var renderedPreview: EmailPreviewRenderModel?
    @State private var isLoading = true
    @State private var loadGeneration = 0
    @State private var remoteImageFallbackReloadTask: Task<Void, Never>?
    @State private var remoteImageFallbackOriginalWarmTask: Task<Void, Never>?
    private let originalEmailSourceWarmer: any OriginalEmailSourceWarming
    private let previewPipeline = EmailPreviewPipeline.shared

    init(
        message: ChatMessageRowModel,
        onOpenFullMessage: @escaping (EmailReaderOpenSource) -> Void,
        originalEmailSourceWarmer: any OriginalEmailSourceWarming = OriginalEmailSourceLoader.shared
    ) {
        self.message = message
        self.onOpenFullMessage = onOpenFullMessage
        self.originalEmailSourceWarmer = originalEmailSourceWarmer
    }

    private var loadKey: String {
        Self.makeLoadKey(
            for: message,
            isDarkMode: colorScheme == .dark,
            htmlSourceSignature: HTMLContentHandler.shared.htmlSourceSignature(
                messageId: message.id,
                bodyStorageURI: message.bodyStorageURI
            )
        )
    }

    /// Identity for the background full-view warm task. The original-email render is appearance
    /// independent (forced light), so this deliberately omits dark mode: a single warm serves both.
    /// Keyed on the source signature so a recovered/changed source re-warms the new content.
    private var warmFullEmailKey: String {
        let sourceSignature = HTMLContentHandler.shared.htmlSourceSignature(
            messageId: message.id,
            bodyStorageURI: message.bodyStorageURI
        )
        return "\(message.id)|\(message.bodyStorageURI ?? "")|warm-original|source:\(sourceSignature)"
    }

    static func makeLoadKey(for message: ChatMessageRowModel, isDarkMode: Bool) -> String {
        makeLoadKey(
            for: message,
            isDarkMode: isDarkMode,
            htmlSourceSignature: HTMLContentHandler.shared.htmlSourceSignature(
                messageId: message.id,
                bodyStorageURI: message.bodyStorageURI
            )
        )
    }

    static func makeLoadKey(
        for message: ChatMessageRowModel,
        isDarkMode: Bool,
        htmlSourceSignature: String?
    ) -> String {
        let bodyTextFingerprint = contentFingerprint(for: message.bodyText)
        let cleanedSnippetFingerprint = contentFingerprint(for: message.cleanedSnippet)
        let subjectFingerprint = contentFingerprint(for: message.subject)
        let senderFingerprint = contentFingerprint(for: message.senderEmail)
        return "\(message.id)|\(message.bodyStorageURI ?? "")|\(bodyTextFingerprint)|\(cleanedSnippetFingerprint)|\(subjectFingerprint)|\(senderFingerprint)|\(isDarkMode)|\(message.htmlDisplayCleanupMode.rawValue)|source:\(htmlSourceSignature ?? "unknown")"
    }

    static func makePreviewHTMLCacheKey(
        messageId: String,
        sourceSignature: String,
        isDarkMode: Bool,
        cleanupMode: HTMLContentCleanupMode
    ) -> String {
        EmailPreviewPipeline.makePreviewHTMLCacheKey(
            messageId: messageId,
            sourceSignature: sourceSignature,
            isDarkMode: isDarkMode,
            cleanupMode: cleanupMode
        )
    }

    static func shouldUseTransactionalPreviewCard(isForwardedEmail: Bool) -> Bool {
        EmailPreviewPipeline.shouldUseTransactionalPreviewCard(isForwardedEmail: isForwardedEmail)
    }

    static func nativePreviewCardRoutes(
        isNewsletter: Bool,
        isForwardedEmail: Bool,
        classificationKind: EmailPreviewKind
    ) -> [NativePreviewCardRoute] {
        EmailPreviewPipeline.nativePreviewCardRoutes(
            isNewsletter: isNewsletter,
            isForwardedEmail: isForwardedEmail,
            classificationKind: classificationKind
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let renderedPreview {
                previewView(for: renderedPreview)
            } else if isLoading {
                Button {
                    onOpenFullMessage(.debugOrFallback)
                } label: {
                    EmailContentPlaceholder()
                }
                .buttonStyle(.plain)
            } else {
                // Fallback when no HTML content available
                // (EmailContentFallback is already tappable, no extra button needed)
                EmailContentFallback(subject: message.subject) {
                    onOpenFullMessage(.debugOrFallback)
                }
            }
        }
        .task(id: loadKey) {
            let generation = await beginLoad()
            await loadHTML(generation: generation)
        }
        // Warm the full original-email HTML while the bubble is visible, so tapping can present
        // prepared content immediately. Active WebView adoption is policy-gated inside the manager.
        // Debounced + capacity-bounded (LRU) inside the manager; auto-cancels when the row scrolls away.
        .task(id: warmFullEmailKey) {
            await warmFullEmailWebViewIfNeeded()
        }
        .onReceive(NotificationCenter.default.publisher(for: HTMLContentLoader.remoteImageAttachmentFallbackDidWarmNotification)) { notification in
            reloadIfRemoteImageFallbackWarmed(notification)
        }
        .onDisappear {
            remoteImageFallbackReloadTask?.cancel()
            remoteImageFallbackReloadTask = nil
            remoteImageFallbackOriginalWarmTask?.cancel()
            remoteImageFallbackOriginalWarmTask = nil
        }
    }

    /// Warms the wrapped full original-email HTML via `FullEmailWebViewManager` so a tap can skip cold
    /// preparation. Debounced so fast scrolling does not do work for rows that immediately leave; the
    /// manager bounds total warmed payloads, de-dupes already-warm content, and keeps active WebView
    /// warming disabled unless adoption is explicitly enabled.
    private func warmFullEmailWebViewIfNeeded() async {
        try? await Task.sleep(nanoseconds: 200_000_000)
        guard !Task.isCancelled else {
            return
        }
        let width = FullEmailWebViewMetrics.fullViewWidth()
        guard width > 1 else {
            return
        }
        await FullEmailWebViewManager.shared.warm(
            request: Self.originalEmailWarmRequest(for: message),
            message: resolvedMessageForInlineAttachments,
            width: width
        )
    }

    private func beginLoad() async -> Int {
        await MainActor.run {
            loadGeneration &+= 1
            isLoading = true
            return loadGeneration
        }
    }

    private func beginBackgroundReload() async -> Int {
        await MainActor.run {
            loadGeneration &+= 1
            if renderedPreview == nil {
                isLoading = true
            }
            return loadGeneration
        }
    }

    private func loadHTML(generation: Int) async {
        let renderedPreview = await previewPipeline.loadPreview(
            request: EmailPreviewPipelineRequest(
                messageId: message.id,
                bodyStorageURI: message.bodyStorageURI,
                bodyText: message.bodyText,
                cleanedSnippet: message.cleanedSnippet,
                senderName: message.senderName,
                senderEmail: message.senderEmail,
                subject: message.subject,
                isNewsletter: message.isNewsletter,
                isForwardedEmail: message.isForwardedEmail,
                cleanupMode: message.htmlDisplayCleanupMode,
                isDarkMode: colorScheme == .dark
            )
        )

        guard !Task.isCancelled else {
            return
        }

        if renderedPreview == nil {
            Log.diagnostic(.htmlPreview, "EmailContentSection: No HTML content for message \(message.id)", category: .ui)
        }

        await finishLoad(with: renderedPreview, generation: generation)
    }

    private func finishLoad(with preview: EmailPreviewRenderModel?, generation: Int) async {
        await MainActor.run {
            guard generation == loadGeneration else {
                return
            }

            renderedPreview = preview
            isLoading = false
        }
    }

    private func reloadIfRemoteImageFallbackWarmed(_ notification: Notification) {
        guard let warmRequest = Self.remoteImageFallbackOriginalWarmRequest(
            for: message,
            notification: notification
        ) else {
            return
        }

        remoteImageFallbackReloadTask?.cancel()
        remoteImageFallbackReloadTask = Task {
            let generation = await beginBackgroundReload()
            await loadHTML(generation: generation)
        }

        remoteImageFallbackOriginalWarmTask = Self.replacingRemoteImageFallbackOriginalWarmTask(
            remoteImageFallbackOriginalWarmTask,
            request: warmRequest,
            warmer: originalEmailSourceWarmer
        )
    }

    @ViewBuilder
    private func previewView(for renderedPreview: EmailPreviewRenderModel) -> some View {
        switch renderedPreview {
        case .calendarInvite(let model):
            Button {
                onOpenFullMessage(.previewCard)
            } label: {
                CalendarInvitePreviewCard(model: model)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Calendar invite: \(model.title)")
            .accessibilityHint("Opens the full original email")
        case .newsletter(let model):
            Button {
                onOpenFullMessage(.previewCard)
            } label: {
                NewsletterPreviewCard(model: model)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Email preview: \(model.title)")
            .accessibilityHint("Opens the full original email")
        case .transactional(let model):
            Button {
                onOpenFullMessage(.previewCard)
            } label: {
                TransactionalPreviewCard(model: model)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Email preview: \(model.title)")
            .accessibilityHint("Opens the full original email")
        case .netlifyDeploy(let model):
            Button {
                onOpenFullMessage(.previewCard)
            } label: {
                NetlifyDeployPreviewCard(model: model)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Netlify deploy preview: \(model.title), \(model.status.displayText)")
            .accessibilityHint("Opens the full original email")
        case .html(let payload):
            Button {
                onOpenFullMessage(.previewCard)
            } label: {
                htmlFallbackPreview(payload)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(transactionalPreviewAccessibilityLabel)
            .accessibilityHint("Opens the full original email")
        }
    }

    @ViewBuilder
    private func htmlFallbackPreview(_ payload: HTMLPreviewPayload) -> some View {
        let isDarkMode = colorScheme == .dark
        let messageForInlineAttachments = resolvedMessageForInlineAttachments

        EmailPreviewSnapshotView(
            htmlContent: payload.html,
            previewCacheKey: payload.previewCacheKey,
            isDarkMode: isDarkMode,
            senderEmail: message.senderEmail,
            message: messageForInlineAttachments,
            messageId: message.id
        )
        .allowsHitTesting(false)
        .emailPreviewCardChrome()
    }

    private var transactionalPreviewAccessibilityLabel: String {
        if let subject = message.subject, !subject.isEmpty {
            return "Email preview: \(subject)"
        }

        return "Email preview"
    }

    private var resolvedMessageForInlineAttachments: Message? {
        if let registered = viewContext.registeredObject(for: message.messageObjectID) as? Message,
           !registered.isDeleted {
            return registered
        }

        guard let resolved = try? viewContext.existingObject(with: message.messageObjectID) as? Message,
              !resolved.isDeleted else {
            return nil
        }

        return resolved
    }

    private static func contentFingerprint(for text: String?) -> String {
        guard let text else {
            return "nil"
        }

        return SHA256.hash(data: Data(text.utf8))
            .prefix(8)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    static func originalEmailWarmRequest(for message: ChatMessageRowModel) -> OriginalEmailWarmRequest {
        OriginalEmailWarmRequest(
            messageId: message.id,
            bodyStorageURI: message.bodyStorageURI,
            bodyText: message.bodyText,
            senderEmail: message.senderEmail,
            subject: message.subject
        )
    }

    static func remoteImageFallbackOriginalWarmRequest(
        for message: ChatMessageRowModel,
        notification: Notification
    ) -> OriginalEmailWarmRequest? {
        guard let warmedMessageId = notification.userInfo?[HTMLContentLoader.remoteImageAttachmentFallbackMessageIdUserInfoKey] as? String,
              warmedMessageId == message.id else {
            return nil
        }

        return originalEmailWarmRequest(for: message)
    }

    static func replacingRemoteImageFallbackOriginalWarmTask(
        _ existingTask: Task<Void, Never>?,
        request: OriginalEmailWarmRequest,
        warmer: any OriginalEmailSourceWarming
    ) -> Task<Void, Never> {
        existingTask?.cancel()
        return Task(priority: .utility) {
            await warmer.warmOriginalEmailSource(request: request)
        }
    }
}
