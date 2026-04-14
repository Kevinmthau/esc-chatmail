import SwiftUI

/// Container view that routes chat previews by content type.
/// Newsletter and strongly-structured transactional emails render as derived native cards.
/// Other rich HTML still falls back to the existing scaled WebView preview.
struct EmailContentSection: View {
    let message: Message
    let onOpenFullMessage: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @State private var renderedPreview: LoadedPreview?
    @State private var isLoading = true
    @State private var loadGeneration = 0
    private let htmlContentLoader = HTMLContentLoader.shared
    private let previewClassifier = EmailPreviewClassifier()
    private let calendarInvitePreviewBuilder = CalendarInvitePreviewBuilder()
    private let newsletterPreviewBuilder = NewsletterPreviewBuilder()
    private let transactionalPreviewBuilder = TransactionalPreviewBuilder()

    private var loadKey: String {
        Self.makeLoadKey(for: message, isDarkMode: colorScheme == .dark)
    }

    static func makeLoadKey(for message: Message, isDarkMode: Bool) -> String {
        let bodyTextHash = message.bodyText?.hashValue ?? 0
        let cleanedSnippetHash = message.cleanedSnippet?.hashValue ?? 0
        let subjectHash = message.subject?.hashValue ?? 0
        let senderHash = message.senderEmail?.hashValue ?? 0
        return "\(message.id)|\(message.bodyStorageURI ?? "")|\(bodyTextHash)|\(cleanedSnippetHash)|\(subjectHash)|\(senderHash)|\(isDarkMode)|\(message.htmlDisplayCleanupMode.rawValue)"
    }

    static func shouldUseTransactionalPreviewCard(isForwardedEmail: Bool) -> Bool {
        !isForwardedEmail
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

        if let canonicalHTML = await htmlContentLoader.loadCanonicalHTML(
            messageId: message.id,
            bodyStorageURI: message.bodyStorageURI,
            bodyText: message.bodyText
        ) {
            guard !Task.isCancelled else {
                return
            }

            let classification = previewClassifier.classify(
                canonicalHTML: canonicalHTML,
                bodyText: message.bodyText,
                senderEmail: message.senderEmail,
                subject: message.subject
            )
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

            switch classification.kind {
            case .newsletter:
                if let model = newsletterPreviewBuilder.buildPreview(
                    canonicalHTML: canonicalHTML,
                    bodyText: message.bodyText,
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
            case .transactional where Self.shouldUseTransactionalPreviewCard(isForwardedEmail: message.isForwardedEmail):
                if let model = transactionalPreviewBuilder.buildPreview(
                    canonicalHTML: canonicalHTML,
                    bodyText: message.bodyText,
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
            case .transactional, .personToPerson:
                break
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

        await finishLoad(with: result.html.map(LoadedPreview.transactionalHTML), generation: generation)
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
        case .transactionalHTML(let html):
            Button(action: onOpenFullMessage) {
                MiniEmailWebView(
                    htmlContent: html,
                    isDarkMode: colorScheme == .dark,
                    message: message
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
}

private enum LoadedPreview: Equatable {
    case calendarInvite(CalendarInvitePreviewModel)
    case newsletter(NewsletterPreviewModel)
    case transactional(TransactionalPreviewModel)
    case transactionalHTML(String)
}
