import SwiftUI

/// Container view that displays a mini WebView preview of newsletter HTML content
struct EmailContentSection: View {
    let message: Message
    @Binding var showingHTMLView: Bool

    @Environment(\.colorScheme) private var colorScheme
    @State private var htmlContent: String?
    @State private var isLoading = true
    @State private var hasLoaded = false
    private let htmlContentLoader = HTMLContentLoader.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let html = htmlContent {
                // Tappable mini WebView preview
                Button(action: { showingHTMLView = true }) {
                    MiniEmailWebView(htmlContent: html, message: message)
                        .frame(height: 200)
                        .cornerRadius(12)
                        .clipped()
                }
                .buttonStyle(PlainButtonStyle())

                // View Full Email button - only shown with thumbnail
                Button(action: {
                    showingHTMLView = true
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: "doc.richtext")
                            .font(.caption)
                        Text("View Full Email")
                            .font(.caption)
                            .fontWeight(.medium)
                        Image(systemName: "arrow.up.forward")
                            .font(.caption2)
                    }
                    .foregroundColor(.blue)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color.blue.opacity(0.1))
                    .cornerRadius(8)
                }
            } else if isLoading {
                EmailContentPlaceholder()
            } else {
                // Fallback when no HTML content available
                // (EmailContentFallback is already tappable, no extra button needed)
                EmailContentFallback(subject: message.subject) {
                    showingHTMLView = true
                }
            }
        }
        .task {
            guard !hasLoaded else { return }
            hasLoaded = true
            await loadHTML()
        }
    }

    private func loadHTML() async {
        let shouldStripQuotedContent = !message.isNewsletter

        let result = await htmlContentLoader.loadContentWithTimeout(
            messageId: message.id,
            bodyStorageURI: message.bodyStorageURI,
            bodyText: message.bodyText,
            isDarkMode: colorScheme == .dark,
            stripQuotedContent: shouldStripQuotedContent,
            timeout: 5.0
        )

        if result.html == nil {
            Log.info("EmailContentSection: No HTML content for message \(message.id)", category: .ui)
        }

        await MainActor.run {
            htmlContent = result.html
            isLoading = false
        }
    }
}
