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
                    MiniEmailWebView(htmlContent: html)
                        .frame(height: 200)
                        .cornerRadius(12)
                        .clipped()
                }
                .buttonStyle(PlainButtonStyle())
            } else if isLoading {
                EmailContentPlaceholder()
            } else {
                // Fallback when no HTML content available
                EmailContentFallback(subject: message.subject) {
                    showingHTMLView = true
                }
            }

            // View Full Email button
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
        }
        .task {
            guard !hasLoaded else { return }
            hasLoaded = true
            await loadHTML()
        }
    }

    private func loadHTML() async {
        let messageId = message.id

        // Try loading from cache first
        let handler = HTMLContentHandler.shared
        if let html = handler.loadHTML(for: messageId) {
            await MainActor.run {
                htmlContent = html
                isLoading = false
            }
            return
        }

        // Try loading from storage URI
        if let uri = message.bodyStorageURI {
            if let resolved = resolveStorageURI(uri) {
                if let html = try? String(contentsOf: resolved, encoding: .utf8) {
                    await MainActor.run {
                        htmlContent = html
                        isLoading = false
                    }
                    return
                }
            }
        }

        Log.info("EmailContentSection: No HTML content for message \(messageId)", category: .ui)
        await MainActor.run {
            isLoading = false
        }
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
