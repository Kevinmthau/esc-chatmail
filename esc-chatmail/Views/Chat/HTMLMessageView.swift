import SwiftUI
import WebKit

// MARK: - Inline HTML Preview for Chat Bubbles
struct HTMLPreviewView: View {
    let message: Message
    let maxHeight: CGFloat
    @Environment(\.colorScheme) private var colorScheme
    @State private var htmlContent: String?
    @State private var isLoading = true

    private let htmlContentLoader = HTMLContentLoader.shared

    var body: some View {
        Group {
            if isLoading {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.gray.opacity(0.1))
                    .frame(height: maxHeight)
                    .overlay(
                        ProgressView()
                            .scaleEffect(0.8)
                    )
            } else if let html = htmlContent {
                HTMLPreviewWebView(
                    htmlContent: html,
                    isDarkMode: colorScheme == .dark,
                    maxHeight: maxHeight,
                    message: message
                )
                .frame(height: maxHeight)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(Color.gray.opacity(0.2), lineWidth: 1)
                )
            } else {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.gray.opacity(0.1))
                    .frame(height: 60)
                    .overlay(
                        Text("Preview unavailable")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    )
            }
        }
        .task {
            await loadHTMLContent()
        }
    }

    private func loadHTMLContent() async {
        let result = await htmlContentLoader.loadContent(
            messageId: message.id,
            bodyStorageURI: message.bodyStorageURI,
            senderEmail: message.senderEmail,
            isDarkMode: colorScheme == .dark,
            cleanupMode: message.htmlDisplayCleanupMode
        )

        await MainActor.run {
            self.htmlContent = result.html
            self.isLoading = false
        }
    }
}

// MARK: - Full HTML Message View
struct HTMLMessageView: View {
    let message: Message
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @State private var htmlContent: String?
    @State private var isLoading = true

    private let htmlContentLoader = HTMLContentLoader.shared

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView("Loading...")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let html = htmlContent {
                    HTMLWebView(
                        htmlContent: html,
                        isDarkMode: colorScheme == .dark,
                        message: message
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ContentUnavailableView(
                        "No Content",
                        systemImage: "doc.text",
                        description: Text("The original email content is not available")
                    )
                }
            }
            .navigationTitle("Original Email")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
        .task {
            await loadHTMLContent()
        }
    }

    private func loadHTMLContent() async {
        Log.info("HTMLMessageView loading message \(message.id)", category: .ui)
        let result = await htmlContentLoader.loadContentWithTimeout(
            messageId: message.id,
            bodyStorageURI: message.bodyStorageURI,
            bodyText: message.bodyText,
            senderEmail: message.senderEmail,
            isDarkMode: colorScheme == .dark,
            cleanupMode: message.htmlDisplayCleanupMode,
            timeout: 5.0
        )

        // If we loaded HTML from the per-message file location (or recovered it and saved it there),
        // ensure Core Data points at the canonical file URL so the rest of the UI can treat it as
        // having a stable HTML source.
        if (result.source == .messageId || result.source == .recovered),
           result.html != nil,
           let context = message.managedObjectContext {
            let messageId = message.id
            Task {
                await context.perform {
                    guard let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
                        return
                    }
                    let messagesDirectory = documentsPath.appendingPathComponent("Messages")
                    let fileURL = messagesDirectory.appendingPathComponent("\(messageId).html")
                    message.bodyStorageURI = fileURL.absoluteString
                    context.saveOrLog(operation: "update message body storage URI")
                }
            }
        }

        await MainActor.run {
            self.htmlContent = result.html
            self.isLoading = false
        }

        Log.info(
            "HTMLMessageView loaded message \(message.id) source=\(String(describing: result.source)) hasHTML=\(result.html != nil)",
            category: .ui
        )
    }
}
