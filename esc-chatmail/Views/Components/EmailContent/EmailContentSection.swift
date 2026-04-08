import SwiftUI

/// Container view that routes chat previews by content type.
/// Newsletter-like email renders as a derived native card; other rich HTML still falls back
/// to the existing scaled WebView preview until those paths get their own dedicated treatment.
struct EmailContentSection: View {
    let message: Message
    let onOpenFullMessage: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @State private var renderedPreview: LoadedPreview?
    @State private var isLoading = true
    private let htmlContentLoader = HTMLContentLoader.shared
    private let previewClassifier = EmailPreviewClassifier()
    private let newsletterPreviewBuilder = NewsletterPreviewBuilder()

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
            await loadHTML()
        }
    }

    private func loadHTML() async {
        await MainActor.run {
            renderedPreview = nil
            isLoading = true
        }

        if let canonicalHTML = await htmlContentLoader.loadCanonicalHTML(
            messageId: message.id,
            bodyStorageURI: message.bodyStorageURI,
            bodyText: message.bodyText
        ) {
            let classification = previewClassifier.classify(
                canonicalHTML: canonicalHTML,
                bodyText: message.bodyText,
                senderEmail: message.senderEmail,
                subject: message.subject
            )

            if classification.kind == .newsletter,
               let model = newsletterPreviewBuilder.buildPreview(
                canonicalHTML: canonicalHTML,
                bodyText: message.bodyText,
                cleanedSnippet: message.cleanedSnippet,
                senderName: message.senderName,
                senderEmail: message.senderEmail,
                subject: message.subject
               ) {
                await MainActor.run {
                    renderedPreview = .newsletter(model)
                    isLoading = false
                }
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
            timeout: 5.0
        )

        if result.html == nil {
            Log.diagnostic(.htmlPreview, "EmailContentSection: No HTML content for message \(message.id)", category: .ui)
        }

        await MainActor.run {
            renderedPreview = result.html.map(LoadedPreview.transactionalHTML)
            isLoading = false
        }
    }

    @ViewBuilder
    private func previewView(for renderedPreview: LoadedPreview) -> some View {
        switch renderedPreview {
        case .newsletter(let model):
            Button(action: onOpenFullMessage) {
                NewsletterPreviewCard(model: model)
            }
            .buttonStyle(.plain)
            .accessibilityHint("Opens the full original email")
        case .transactionalHTML(let html):
            Button(action: onOpenFullMessage) {
                MiniEmailWebView(htmlContent: html, message: message)
                    .allowsHitTesting(false)
                    .frame(height: 200)
                    .cornerRadius(12)
                    .clipped()
            }
            .buttonStyle(.plain)
            .accessibilityHint("Opens the full original email")
        }
    }
}

private enum LoadedPreview: Equatable {
    case newsletter(NewsletterPreviewModel)
    case transactionalHTML(String)
}
