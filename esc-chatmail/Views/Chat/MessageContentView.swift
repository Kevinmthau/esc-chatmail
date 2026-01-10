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
        if let text = fullTextContent ?? message.cleanedSnippet ?? cleanedSnippet(message.snippet), !text.isEmpty {
            textBubble(text: text)
        } else if message.bodyStorageURI != nil || htmlContentHandler.htmlFileExists(for: message.id) {
            // No text content but HTML exists - show button to view it
            ViewContentButton.viewEmail {
                showingHTMLView = true
            }
        } else if message.typedAttachments.isEmpty {
            // No content and no attachments - show placeholder
            noContentPlaceholder
        }
        // If message has attachments but no text, show nothing (attachments are the content)
    }

    @ViewBuilder
    private func textBubble(text: String) -> some View {
        let (displayText, wasTruncated) = truncatedText(text, lineLimit: style.textLineLimit)
        let showViewMore = hasRichContent || wasTruncated

        VStack(alignment: message.isFromMe ? .trailing : .leading, spacing: 6) {
            Text(displayText)
                .padding(style.bubblePadding)
                .background(style.bubbleBackground(isFromMe: message.isFromMe))
                .foregroundColor(style.textColor(isFromMe: message.isFromMe))
                .cornerRadius(style.bubbleCornerRadius)

            if showViewMore {
                ViewContentButton.viewMore {
                    showingHTMLView = true
                }
            }
        }
    }

    /// Truncates text at the specified limits and adds ellipsis if truncated
    private func truncatedText(_ text: String, lineLimit: Int?, charLimit: Int = 800) -> (text: String, wasTruncated: Bool) {
        let maxLines = lineLimit ?? 15
        let lines = text.components(separatedBy: .newlines)

        // Check line limit first
        if lines.count > maxLines {
            let truncated = lines.prefix(maxLines).joined(separator: "\n")
            return (truncated + "...", true)
        }

        // Check character limit
        if text.count > charLimit {
            let truncated = String(text.prefix(charLimit))
            // Try to break at word boundary
            if let lastSpace = truncated.lastIndex(of: " "),
               truncated.distance(from: truncated.startIndex, to: lastSpace) > charLimit - 50 {
                return (String(truncated[..<lastSpace]) + "...", true)
            }
            return (truncated + "...", true)
        }

        return (text, false)
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

    /// Cleans a raw snippet by removing quoted text and signatures
    private func cleanedSnippet(_ snippet: String?) -> String? {
        guard let snippet = snippet else { return nil }
        let cleaned = PlainTextQuoteRemover.removeQuotes(from: snippet)
        return cleaned?.isEmpty == true ? nil : cleaned
    }
}
