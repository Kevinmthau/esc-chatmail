import SwiftUI
import CoreData
import CryptoKit

/// Container view that routes chat previews by content type.
/// Newsletter and strongly-structured transactional emails render as derived native cards.
/// Other rich HTML still falls back to the existing scaled WebView preview.
struct EmailContentSection: View {
    let message: ChatMessageRowModel
    let onOpenFullMessage: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.managedObjectContext) private var viewContext
    @State private var renderedPreview: LoadedPreview?
    @State private var isLoading = true
    @State private var loadGeneration = 0
    private let htmlContentLoader = HTMLContentLoader.shared
    private let previewSourceLoader = EmailPreviewSourceLoader.shared
    private let calendarInvitePreviewBuilder = CalendarInvitePreviewBuilder()
    private let newsletterPreviewBuilder = NewsletterPreviewBuilder()
    private let transactionalPreviewBuilder = TransactionalPreviewBuilder()
    private let netlifyDeployPreviewBuilder = NetlifyDeployPreviewBuilder()

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
        "\(messageId)|\(sourceSignature)|mode:html-preview|dark:\(isDarkMode)|cleanup:\(cleanupMode.rawValue)"
    }

    static func shouldUseTransactionalPreviewCard(isForwardedEmail: Bool) -> Bool {
        !isForwardedEmail
    }

    static func nativePreviewCardRoutes(
        isNewsletter: Bool,
        isForwardedEmail: Bool,
        classificationKind: EmailPreviewKind
    ) -> [NativePreviewCardRoute] {
        var routes: [NativePreviewCardRoute] = []

        if classificationKind == .transactional,
           shouldUseTransactionalPreviewCard(isForwardedEmail: isForwardedEmail) {
            routes.append(.transactional)
        }

        if !isForwardedEmail,
           classificationKind == .newsletter || isNewsletter {
            routes.append(.newsletter)
        }

        return routes
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let renderedPreview {
                previewView(for: renderedPreview)
            } else if isLoading {
                Button(action: onOpenFullMessage) {
                    EmailContentPlaceholder()
                }
                .buttonStyle(.plain)
            } else {
                // Fallback when no HTML content available
                // (EmailContentFallback is already tappable, no extra button needed)
                EmailContentFallback(subject: message.subject) {
                    onOpenFullMessage()
                }
            }
        }
        .task(id: loadKey) {
            let generation = await beginLoad()
            await loadHTML(generation: generation)
        }
    }

    private func beginLoad() async -> Int {
        await MainActor.run {
            loadGeneration &+= 1
            isLoading = true
            return loadGeneration
        }
    }

    private func loadHTML(generation: Int) async {
        let previewSource = await previewSourceLoader.loadPreviewSource(
            messageId: message.id,
            bodyStorageURI: message.bodyStorageURI,
            bodyText: message.bodyText,
            senderEmail: message.senderEmail,
            subject: message.subject,
            allowRecovery: true
        )

        if let previewSource,
           let canonicalHTML = previewSource.canonicalHTML {
            guard !Task.isCancelled else {
                return
            }

            let classification = previewSource.classification
            Log.diagnostic(
                .htmlPreview,
                level: .info,
                "EmailContentSection classified message \(message.id): \(classification.diagnosticSummary)",
                category: .ui
            )

            if !message.isForwardedEmail,
               let model = calendarInvitePreviewBuilder.buildPreview(
                canonicalHTML: canonicalHTML,
                bodyText: message.bodyText,
                cleanedSnippet: message.cleanedSnippet,
                senderName: message.senderName,
                senderEmail: message.senderEmail,
                subject: message.subject
               ) {
                await finishLoad(with: .calendarInvite(model), generation: generation)
                return
            }

            if !message.isForwardedEmail,
               let model = netlifyDeployPreviewBuilder.buildPreview(
                canonicalHTML: canonicalHTML,
                senderEmail: message.senderEmail,
                subject: message.subject
               ) {
                await finishLoad(with: .netlifyDeploy(model), generation: generation)
                return
            }

            let routes = Self.nativePreviewCardRoutes(
                isNewsletter: message.isNewsletter,
                isForwardedEmail: message.isForwardedEmail,
                classificationKind: classification.kind
            )

            for route in routes {
                switch route {
                case .newsletter:
                    if let model = newsletterPreviewBuilder.buildPreview(
                        source: previewSource,
                        cleanedSnippet: message.cleanedSnippet,
                        senderName: message.senderName,
                        senderEmail: message.senderEmail,
                        subject: message.subject
                    ) {
                        await finishLoad(with: .newsletter(model), generation: generation)
                        return
                    }

                    Log.diagnostic(
                        .htmlPreview,
                        level: .info,
                        "EmailContentSection newsletter fallback for message \(message.id): preview model unavailable",
                        category: .ui
                    )
                case .transactional:
                    if let model = transactionalPreviewBuilder.buildPreview(
                        source: previewSource,
                        cleanedSnippet: message.cleanedSnippet,
                        senderName: message.senderName,
                        senderEmail: message.senderEmail,
                        subject: message.subject
                    ) {
                        await finishLoad(with: .transactional(model), generation: generation)
                        return
                    }

                    Log.diagnostic(
                        .htmlPreview,
                        level: .info,
                        "EmailContentSection transactional fallback for message \(message.id): preview model unavailable",
                        category: .ui
                    )
                }
            }

            if let previewHTML = await htmlContentLoader.preparePreviewHTML(
                fromCanonicalHTML: canonicalHTML,
                messageId: message.id,
                bodyText: message.bodyText,
                senderEmail: message.senderEmail,
                subject: message.subject,
                isDarkMode: colorScheme == .dark,
                cleanupMode: message.htmlDisplayCleanupMode
            ) {
                await finishLoad(
                    with: .transactionalHTML(
                        HTMLPreviewPayload(
                            html: previewHTML,
                            previewCacheKey: Self.makePreviewHTMLCacheKey(
                                messageId: message.id,
                                sourceSignature: previewSource.sourceSignature,
                                isDarkMode: colorScheme == .dark,
                                cleanupMode: message.htmlDisplayCleanupMode
                            )
                        )
                    ),
                    generation: generation
                )
                return
            }
        }

        let result = await htmlContentLoader.loadContentWithTimeout(
            messageId: message.id,
            bodyStorageURI: message.bodyStorageURI,
            bodyText: message.bodyText,
            senderEmail: message.senderEmail,
            isDarkMode: colorScheme == .dark,
            cleanupMode: message.htmlDisplayCleanupMode,
            displayPurpose: .preview,
            timeout: 5.0
        )

        guard !Task.isCancelled else {
            return
        }

        if result.html == nil {
            Log.diagnostic(.htmlPreview, "EmailContentSection: No HTML content for message \(message.id)", category: .ui)
        }

        let loadedPreview = result.html.map { html in
            LoadedPreview.transactionalHTML(
                HTMLPreviewPayload(
                    html: html,
                    previewCacheKey: Self.makePreviewHTMLCacheKey(
                        messageId: message.id,
                        sourceSignature: result.sourceSignature ?? Self.htmlContentSignature(for: html),
                        isDarkMode: colorScheme == .dark,
                        cleanupMode: message.htmlDisplayCleanupMode
                    )
                )
            )
        }
        await finishLoad(with: loadedPreview, generation: generation)
    }

    private func finishLoad(with preview: LoadedPreview?, generation: Int) async {
        await MainActor.run {
            guard generation == loadGeneration else {
                return
            }

            renderedPreview = preview
            isLoading = false
        }
    }

    @ViewBuilder
    private func previewView(for renderedPreview: LoadedPreview) -> some View {
        switch renderedPreview {
        case .calendarInvite(let model):
            Button(action: onOpenFullMessage) {
                CalendarInvitePreviewCard(model: model)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Calendar invite: \(model.title)")
            .accessibilityHint("Opens the full original email")
        case .newsletter(let model):
            Button(action: onOpenFullMessage) {
                NewsletterPreviewCard(model: model)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Email preview: \(model.title)")
            .accessibilityHint("Opens the full original email")
        case .transactional(let model):
            Button(action: onOpenFullMessage) {
                TransactionalPreviewCard(model: model)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Email preview: \(model.title)")
            .accessibilityHint("Opens the full original email")
        case .netlifyDeploy(let model):
            Button(action: onOpenFullMessage) {
                NetlifyDeployPreviewCard(model: model)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Netlify deploy preview: \(model.title), \(model.status.displayText)")
            .accessibilityHint("Opens the full original email")
        case .transactionalHTML(let payload):
            Button(action: onOpenFullMessage) {
                MiniEmailWebView(
                    htmlContent: payload.html,
                    previewCacheKey: payload.previewCacheKey,
                    isDarkMode: colorScheme == .dark,
                    senderEmail: message.senderEmail,
                    message: resolvedMessageForInlineAttachments
                )
                    .allowsHitTesting(false)
                    .emailPreviewCardChrome()
            }
            .buttonStyle(.plain)
            .accessibilityLabel(transactionalPreviewAccessibilityLabel)
            .accessibilityHint("Opens the full original email")
        }
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

    private static func htmlContentSignature(for html: String) -> String {
        let digest = SHA256.hash(data: Data(html.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return "html:\(digest)"
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
}

enum NativePreviewCardRoute: Equatable {
    case newsletter
    case transactional
}

private enum LoadedPreview: Equatable {
    case calendarInvite(CalendarInvitePreviewModel)
    case newsletter(NewsletterPreviewModel)
    case transactional(TransactionalPreviewModel)
    case netlifyDeploy(NetlifyDeployPreviewModel)
    case transactionalHTML(HTMLPreviewPayload)
}

private struct HTMLPreviewPayload: Equatable {
    let html: String
    let previewCacheKey: String
}
