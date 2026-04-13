import SwiftUI

/// Displays the content portion of a message bubble.
/// Handles rich HTML, plain text, attachments, and empty states.
struct MessageContentView: View {
    let message: Message
    let style: MessageBubbleStyle
    let showHTMLPreview: Bool
    let fullTextContent: String?
    let hasLoadedContent: Bool
    let forwardedDisplayContent: ForwardedMessageDisplayContent?
    let onOpenFullMessage: () -> Void

    var body: some View {
        if showHTMLPreview {
            // Preview-card mode is reserved for forwarded, newsletter, and rich transactional HTML.
            EmailContentSection(
                message: message,
                onOpenFullMessage: onOpenFullMessage
            )
            .frame(maxWidth: style.maxBubbleWidth, alignment: message.isFromMe ? .trailing : .leading)
        } else {
            // Personal emails: Show as chat bubbles with text
            textContent
        }
    }

    @ViewBuilder
    private var textContent: some View {
        if let forwardedDisplay = resolvedForwardedDisplayContent {
            forwardedTextContent(for: forwardedDisplay)
        } else if message.hasHTMLSource && !hasLoadedContent {
            // Avoid flashing raw/partial HTML-derived text while async content detection is still running.
            loadingPlaceholder
        } else {
            // Fallback chain:
            // 1. fullTextContent - Async-loaded processed text (best quality, but may not be ready on first render)
            // 2. processedText(bodyText) - Full body text with processing (immediate, full content)
            // 3. processedText(snippet) - Gmail API snippet with processing (truncated, rarely used)
            // 4. message.snippet - Raw truncated snippet (last resort)
            // Note: We skip message.cleanedSnippet because TextSnippetCreator destroys all newlines
            if let text = fullTextContent ?? cachedProcessedText ?? message.snippet, !text.isEmpty {
                textBubble(text: text)
            } else if message.hasHTMLSource {
                // No text content but HTML exists - show a tappable bubble to open full email
                openEmailBubble
            } else if message.typedAttachments.isEmpty {
                // No content and no attachments - show placeholder
                noContentPlaceholder
            }
            // If message has attachments but no text, show nothing (attachments are the content)
        }
    }

    private var loadingPlaceholder: some View {
        Button(action: openOriginalEmail) {
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("Loading...")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(style.bubblePadding)
            .background(style.bubbleBackground(isFromMe: message.isFromMe))
            .cornerRadius(style.bubbleCornerRadius)
        }
        .buttonStyle(.plain)
        .accessibilityHint("Opens the full original email")
    }

    @ViewBuilder
    private func textBubble(text: String) -> some View {
        let compactCharLimit = style.textLineLimit == nil ? nil : 800
        let (displayText, _) = truncatedText(text, lineLimit: style.textLineLimit, charLimit: compactCharLimit)

        Button(action: openOriginalEmail) {
            Text(displayText)
                .padding(style.bubblePadding)
                .background(style.bubbleBackground(isFromMe: message.isFromMe))
                .foregroundColor(style.textColor(isFromMe: message.isFromMe))
                .cornerRadius(style.bubbleCornerRadius)
        }
        .buttonStyle(.plain)
        .accessibilityHint("Opens the full original email")
    }

    @ViewBuilder
    private func forwardedTextContent(for content: ForwardedMessageDisplayContent) -> some View {
        Button(action: openOriginalEmail) {
            VStack(alignment: .leading, spacing: 10) {
                if let leadInText = resolvedLeadInText(from: content) {
                    Text(leadInText)
                        .foregroundColor(style.textColor(isFromMe: message.isFromMe))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                ForwardedMessageCard(
                    content: content,
                    subjectFallback: message.forwardedDisplaySubject
                )
            }
            .padding(style.bubblePadding)
            .background(style.bubbleBackground(isFromMe: message.isFromMe))
            .cornerRadius(style.bubbleCornerRadius)
        }
        .buttonStyle(.plain)
        .accessibilityHint("Opens the full original email")
    }

    /// Truncates text at the specified limits and adds ellipsis if truncated
    private func truncatedText(_ text: String, lineLimit: Int?, charLimit: Int? = nil) -> (text: String, wasTruncated: Bool) {
        if let maxLines = lineLimit {
            let lines = text.components(separatedBy: .newlines)
            if lines.count > maxLines {
                let truncated = lines.prefix(maxLines).joined(separator: "\n")
                return (truncated + "...", true)
            }
        }

        // Check character limit
        if let charLimit, text.count > charLimit {
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
        Button(action: openOriginalEmail) {
            Text("No preview available")
                .font(.caption)
                .foregroundColor(.secondary)
                .italic()
                .padding(10)
                .background(Color.gray.opacity(0.1))
                .cornerRadius(12)
        }
        .buttonStyle(.plain)
        .accessibilityHint("Opens the full original email")
    }

    private var openEmailBubble: some View {
        Button(action: openOriginalEmail) {
            HStack(spacing: 6) {
                Image(systemName: "doc.richtext")
                    .font(.caption)
                Text("Open original email")
                    .font(.caption)
                    .fontWeight(.medium)
            }
            .foregroundColor(.blue)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.blue.opacity(0.1))
            .cornerRadius(8)
        }
        .buttonStyle(.plain)
    }

    private func openOriginalEmail() {
        onOpenFullMessage()
    }

    /// Pre-computes the fallback processed text from bodyText or snippet.
    /// Avoids calling processedText() multiple times during view body evaluation.
    private var cachedProcessedText: String? {
        Self.resolvedProcessedText(bodyText: message.bodyText, snippet: message.snippet)
    }

    private var resolvedForwardedDisplayContent: ForwardedMessageDisplayContent? {
        forwardedDisplayContent ?? message.outgoingForwardedDisplayContent
    }

    private func resolvedLeadInText(from content: ForwardedMessageDisplayContent) -> String? {
        let baseText = content.leadInText
        guard let baseText, !baseText.isEmpty else {
            return nil
        }

        let compactCharLimit = style.textLineLimit == nil ? nil : 800
        let (displayText, _) = truncatedText(
            baseText,
            lineLimit: style.textLineLimit,
            charLimit: compactCharLimit
        )
        return displayText
    }

    static func resolvedProcessedText(bodyText: String?, snippet: String?) -> String? {
        if let processedBody = processedText(bodyText) {
            return processedBody
        }
        if let processedSnippet = processedText(snippet) {
            return processedSnippet
        }
        return nil
    }

    /// Processes text while preserving paragraph structure and decoding HTML entities
    /// Uses the same processing as ProcessedTextCache but preserves line breaks
    /// (unlike cleanedSnippet which destroyed all newlines for conversation list previews)
    private static func processedText(_ text: String?) -> String? {
        let result = ChatBubbleTextProcessor.process(
            content: text,
            options: ChatBubbleTextProcessorOptions(
                inputKind: .autoDetectHTML,
                sanitizeRawEmailSource: true,
                decodeHTMLEntities: true,
                formatSignOffLineBreaks: true,
                classifyRichContent: false
            )
        )
        return result.mainText
    }
}
