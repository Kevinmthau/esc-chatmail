import SwiftUI

/// Displays the content portion of a message bubble.
/// Handles rich HTML, plain text, attachments, and empty states.
struct MessageContentView: View {
    let message: Message
    let style: MessageBubbleStyle
    let hasRichContent: Bool
    let fullTextContent: String?
    @Binding var showingHTMLView: Bool

    private var htmlContentHandler: HTMLContentHandler { HTMLContentHandler.shared }

    var body: some View {
        if message.isNewsletter || hasRichContent {
            // Rich HTML emails (newsletters, bank statements, etc.): Show HTML preview
            EmailContentSection(
                message: message,
                showingHTMLView: $showingHTMLView
            )
            .frame(maxWidth: style.maxBubbleWidth)
        } else {
            // Personal emails: Show as chat bubbles with text
            textContent
        }
    }

    @ViewBuilder
    private var textContent: some View {
        if let text = fullTextContent ?? message.cleanedSnippet ?? message.snippet, !text.isEmpty {
            textBubble(text: text)
        } else if message.bodyStorageURI != nil || htmlContentHandler.htmlFileExists(for: message.id) {
            // No text content but HTML exists - show button to view it
            ViewContentButton.viewEmail {
                showingHTMLView = true
            }
        } else {
            // No content available at all - show minimal placeholder
            noContentPlaceholder
        }
    }

    @ViewBuilder
    private func textBubble(text: String) -> some View {
        let lineCount = text.components(separatedBy: .newlines).count
        let isTruncated = lineCount > (style.textLineLimit ?? 15) || text.count > 800

        VStack(alignment: message.isFromMe ? .trailing : .leading, spacing: 6) {
            Text(text)
                .lineLimit(style.textLineLimit)
                .padding(style.bubblePadding)
                .background(style.bubbleBackground(isFromMe: message.isFromMe))
                .foregroundColor(style.textColor(isFromMe: message.isFromMe))
                .cornerRadius(style.bubbleCornerRadius)

            if hasRichContent || isTruncated {
                ViewContentButton.viewMore {
                    showingHTMLView = true
                }
            }
        }
    }

    private var noContentPlaceholder: some View {
        Text("No preview available")
            .font(.caption)
            .foregroundColor(.secondary)
            .italic()
            .padding(10)
            .background(Color.gray.opacity(0.1))
            .cornerRadius(12)
    }
}
