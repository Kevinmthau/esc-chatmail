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
    let fullEmailOpener: any FullEmailOpening
    let originalEmailSourceWarmer: any OriginalEmailSourceWarming
    let htmlSourceSignaturer: any HTMLSourceSignaturing
    let onOpenFullMessage: (EmailReaderOpenSource) -> Void

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
        VStack(alignment: message.isFromMe ? .trailing : .leading, spacing: 10) {
            EmailContentSection(
                message: message,
                onOpenFullMessage: openOriginalEmail(source:),
                originalEmailSourceWarmer: originalEmailSourceWarmer,
                fullEmailOpener: fullEmailOpener,
                htmlSourceSignaturer: htmlSourceSignaturer
            )

            if !sharedDocumentLinks.isEmpty {
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
            } else if message.attachments.isEmpty {
                // No content and no attachments - show a placeholder that opens the original on tap.
                // An HTML body with no extractable text lands here too, deliberately: no
                // "View original" bubble.
                noContentPlaceholder
            }
            // If message has attachments but no text, show nothing (attachments are the content;
            // any original stays reachable from the long-press menu)
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
        Button {
            openOriginalEmail(source: .debugOrFallback)
        } label: {
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

        if MessageOriginalEmailOpenPolicy.bodyTapOpensOriginal(
            showHTMLPreview: showHTMLPreview,
            hasOriginalEmailContent: message.hasOriginalEmailContent
        ) {
            // The bubble is the tap target; there is deliberately no separate "View original"
            // control. Not `.textSelection(.enabled)`: the bubble is a button, and long-press
            // belongs to the row's message context menu.
            Button {
                openOriginalEmail(source: .textBubble)
            } label: {
                textBubbleBody(displayText)
            }
            .buttonStyle(.plain)
            .accessibilityHint("Opens the full original email")
        } else {
            textBubbleBody(displayText)
                .textSelection(.enabled)
        }
    }

    private func textBubbleBody(_ displayText: String) -> some View {
        Text(displayText)
            .padding(style.bubblePadding)
            .background(style.bubbleBackground(isFromMe: message.isFromMe))
            .foregroundColor(style.textColor(isFromMe: message.isFromMe))
            .cornerRadius(style.bubbleCornerRadius)
    }

    /// The whole bubble (lead-in note and forwarded card) opens the original, like a text bubble.
    @ViewBuilder
    private func forwardedTextContent(for content: ForwardedMessageDisplayContent) -> some View {
        Button {
            openOriginalEmail(source: .previewCard)
        } label: {
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
        Button {
            openOriginalEmail(source: .debugOrFallback)
        } label: {
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

    private func openOriginalEmail(source: EmailReaderOpenSource) {
        onOpenFullMessage(source)
    }

    private var resolvedVisibleText: String? {
        Self.resolvedVisibleText(
            fullTextContent: fullTextContent,
            fallbackPreviewText: fallbackPreviewText,
            chatPreviewText: message.chatPreviewText,
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

    static func resolvedVisibleText(
        fullTextContent: String?,
        fallbackPreviewText: String?,
        chatPreviewText: String? = nil,
        sharedDocumentLinks: [SharedDocumentLink] = []
    ) -> String? {
        let storedChatPreviewText = nonEmptyText(chatPreviewText)
        let sourceText = storedChatPreviewText ?? fullTextContent ?? fallbackPreviewText
        return SharedDocumentLinkExtractor.removingLinks(from: sourceText, matching: sharedDocumentLinks)
    }

    private static func nonEmptyText(_ text: String?) -> String? {
        guard let text,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return text
    }
}

enum MessageOriginalEmailOpenPolicy {
    /// Whether tapping the message body opens the original email. Tapping the message is the
    /// only inline way in — there is deliberately no "View original" control beside the bubble
    /// (the long-press menu keeps "View original email", behind the same content gate). Rich
    /// previews always open; a text bubble opens whenever there is original content behind it.
    static func bodyTapOpensOriginal(showHTMLPreview: Bool, hasOriginalEmailContent: Bool) -> Bool {
        showHTMLPreview || hasOriginalEmailContent
    }

    static func hasOriginalEmailContent(
        hasHTMLSource: Bool,
        bodyStorageURI: String?,
        bodyText: String?
    ) -> Bool {
        hasHTMLSource ||
            nonEmptyText(bodyStorageURI) != nil ||
            nonEmptyText(bodyText) != nil
    }

    private static func nonEmptyText(_ text: String?) -> String? {
        guard let text,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return text
    }
}
