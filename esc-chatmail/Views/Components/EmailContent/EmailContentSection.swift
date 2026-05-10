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
    @State private var renderedPreview: EmailPreviewRenderModel?
    @State private var isLoading = true
    @State private var loadGeneration = 0
    private let previewPipeline = EmailPreviewPipeline.shared

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

    @ViewBuilder
    private func previewView(for renderedPreview: EmailPreviewRenderModel) -> some View {
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
        case .html(let payload):
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
