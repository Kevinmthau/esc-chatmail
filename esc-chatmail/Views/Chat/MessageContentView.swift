import SwiftUI

/// Displays the content portion of a message bubble.
/// Handles rich HTML, plain text, attachments, and empty states.
struct MessageContentView: View {
    let message: ChatMessageRowModel
    let style: MessageBubbleStyle
    let showHTMLPreview: Bool
    let hasHTMLSource: Bool
    let fullTextContent: String?
    let fallbackPreviewText: String?
    let sharedDocumentLinks: [SharedDocumentLink]
    let hasLoadedContent: Bool
    let forwardedDisplayContent: ForwardedMessageDisplayContent?
    let onOpenFullMessage: () -> Void

    var body: some View {
        if showHTMLPreview {
            htmlPreviewContent
                .frame(maxWidth: style.maxBubbleWidth, alignment: message.isFromMe ? .trailing : .leading)
        } else {
            // Personal emails: Show as chat bubbles with text
            textContent
        }
    }

    @ViewBuilder
    private var htmlPreviewContent: some View {
        // Keep shared document cards visible even when the message routes through HTML preview mode.
        if sharedDocumentLinks.isEmpty {
            EmailContentSection(
                message: message,
                onOpenFullMessage: onOpenFullMessage
            )
        } else {
            VStack(alignment: message.isFromMe ? .trailing : .leading, spacing: 10) {
                EmailContentSection(
                    message: message,
                    onOpenFullMessage: onOpenFullMessage
                )
                sharedDocumentCards
            }
        }
    }

    @ViewBuilder
    private var textContent: some View {
        if let forwardedDisplay = resolvedForwardedDisplayContent {
            forwardedTextContent(for: forwardedDisplay)
        } else if message.isForwardedEmail && !hasLoadedContent {
            loadingPlaceholder
        } else if hasHTMLSource && !hasLoadedContent {
            // Avoid flashing raw/partial HTML-derived text while async content detection is still running.
            loadingPlaceholder
        } else {
            if let text = resolvedVisibleText, !text.isEmpty {
                textAndSharedDocumentContent(text: text)
            } else if !sharedDocumentLinks.isEmpty {
                sharedDocumentCards
            } else if hasHTMLSource {
                // No text content but HTML exists - show a tappable bubble to open full email
                openEmailBubble
            } else if message.attachments.isEmpty {
                // No content and no attachments - show placeholder
                noContentPlaceholder
            }
            // If message has attachments but no text, show nothing (attachments are the content)
        }
    }

    @ViewBuilder
    private func textAndSharedDocumentContent(text: String) -> some View {
        if sharedDocumentLinks.isEmpty {
            textBubble(text: text)
        } else {
            VStack(alignment: message.isFromMe ? .trailing : .leading, spacing: 8) {
                textBubble(text: text)
                sharedDocumentCards
            }
        }
    }

    private var sharedDocumentCards: some View {
        VStack(spacing: 10) {
            ForEach(sharedDocumentLinks) { link in
                SharedDocumentLinkCard(link: link)
            }
        }
        .frame(maxWidth: style.maxBubbleWidth, alignment: message.isFromMe ? .trailing : .leading)
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
                    subjectFallback: message.forwardedDisplaySubject,
                    isFromMe: message.isFromMe
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

    private var resolvedVisibleText: String? {
        Self.resolvedVisibleText(
            fullTextContent: fullTextContent,
            fallbackPreviewText: fallbackPreviewText,
            chatPreviewText: message.chatPreviewText,
            outgoingBodyText: message.bodyText,
            isOutgoingPlainTextMessage: message.isFromMe && !message.isForwardedEmail,
            sharedDocumentLinks: sharedDocumentLinks
        )
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

    static func resolvedVisibleText(
        fullTextContent: String?,
        fallbackPreviewText: String?,
        chatPreviewText: String? = nil,
        outgoingBodyText: String?,
        isOutgoingPlainTextMessage: Bool,
        sharedDocumentLinks: [SharedDocumentLink] = []
    ) -> String? {
        let outgoingBodyFallback = isOutgoingPlainTextMessage
            ? MessageBubbleTextPrecedence.preferredOutgoingBodyFallback(
                processedText(outgoingBodyText),
                comparedTo: [
                    fullTextContent,
                    chatPreviewText
                ]
            )
            : nil
        let sourceText = outgoingBodyFallback ?? fullTextContent ?? chatPreviewText ?? fallbackPreviewText
        return SharedDocumentLinkExtractor.removingLinks(from: sourceText, matching: sharedDocumentLinks)
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
