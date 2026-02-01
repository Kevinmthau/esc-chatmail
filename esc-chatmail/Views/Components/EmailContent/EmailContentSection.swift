import SwiftUI

/// Container view that displays a mini WebView preview of newsletter HTML content
struct EmailContentSection: View {
    let message: Message
    @Binding var showingHTMLView: Bool

    @State private var htmlContent: String?
    @State private var isLoading = true
    @State private var hasLoaded = false

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
        let messageId = message.id
        let handler = HTMLContentHandler.shared

        // Method 1: Try loading from message ID (checks if file exists)
        if handler.htmlFileExists(for: messageId),
           let html = handler.loadHTML(for: messageId) {
            await MainActor.run {
                htmlContent = html
                isLoading = false
            }
            return
        }

        // Method 2: Try loading from storage URI
        if let uri = message.bodyStorageURI,
           let resolved = resolveStorageURI(uri),
           FileManager.default.fileExists(atPath: resolved.path),
           let html = try? String(contentsOf: resolved, encoding: .utf8) {
            await MainActor.run {
                htmlContent = html
                isLoading = false
            }
            return
        }

        // Method 3: Recovery - fetch from Gmail API if local content missing
        // Try recovery before plain text fallback to get proper HTML formatting
        if let html = await HTMLContentRecoveryService.shared.recoverHTMLContent(messageId: messageId) {
            await MainActor.run {
                htmlContent = html
                isLoading = false
            }
            return
        }

        // Method 4: Fallback to bodyText (last resort, loses HTML formatting)
        if let text = message.bodyText, !text.isEmpty {
            let html = convertPlainTextToHTML(text)
            await MainActor.run {
                htmlContent = html
                isLoading = false
            }
            return
        }

        Log.info("EmailContentSection: No HTML content for message \(messageId)", category: .ui)
        await MainActor.run {
            isLoading = false
        }
    }

    private func convertPlainTextToHTML(_ text: String) -> String {
        let escaped = text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\n", with: "<br>")

        return """
        <html>
        <body style="font-family: -apple-system, system-ui; padding: 10px;">
        \(escaped)
        </body>
        </html>
        """
    }

    /// Resolves a storage URI string to a valid file URL
    private func resolveStorageURI(_ urlString: String) -> URL? {
        if urlString.starts(with: "/") {
            return URL(fileURLWithPath: urlString)
        } else if urlString.starts(with: "file://") {
            return URL(string: urlString)
        }
        return nil
    }
}
