import SwiftUI

/// Container view that displays a mini WebView preview of newsletter HTML content
struct EmailContentSection: View {
    let message: Message
    @Binding var showingHTMLView: Bool

    @Environment(\.colorScheme) private var colorScheme
    @State private var htmlContent: String?
    @State private var isLoading = true
    private let htmlContentLoader = HTMLContentLoader.shared

    private var loadKey: String {
        let bodyTextHash = message.bodyText?.hashValue ?? 0
        return "\(message.id)|\(message.bodyStorageURI ?? "")|\(bodyTextHash)|\(colorScheme == .dark)|\(message.htmlDisplayCleanupMode.rawValue)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let html = htmlContent {
                // Use an overlay tap target to ensure taps are captured even with embedded WKWebView
                MiniEmailWebView(htmlContent: html, message: message)
                    .frame(height: 200)
                    .cornerRadius(12)
                    .clipped()
                    .overlay {
                        Rectangle()
                            .fill(Color.clear)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                showingHTMLView = true
                            }
                    }
                    .accessibilityAddTraits(.isButton)
                    .accessibilityHint("Opens the full original email")
            } else if isLoading {
                Button(action: { showingHTMLView = true }) {
                    EmailContentPlaceholder()
                }
                .buttonStyle(PlainButtonStyle())
            } else {
                // Fallback when no HTML content available
                // (EmailContentFallback is already tappable, no extra button needed)
                EmailContentFallback(subject: message.subject) {
                    showingHTMLView = true
                }
            }
        }
        .task(id: loadKey) {
            await loadHTML()
        }
    }

    private func loadHTML() async {
        if htmlContent == nil {
            await MainActor.run {
                isLoading = true
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
            Log.info("EmailContentSection: No HTML content for message \(message.id)", category: .ui)
        }

        await MainActor.run {
            htmlContent = result.html
            isLoading = false
        }
    }
}
