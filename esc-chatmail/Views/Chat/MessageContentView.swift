import SwiftUI

/// Displays the content portion of a message bubble.
/// Handles rich HTML, plain text, attachments, and empty states.
struct MessageContentView: View {
    let message: ChatMessageRowModel
    let style: MessageBubbleStyle
    let showHTMLPreview: Bool
    /// The routing input `showHTMLPreview` was decided on (`MessageBubble.displayInput`).
    let displayInput: MessageDisplayInput
    /// Whether `displayInput`'s rich-content verdict is one the load will not change, from
    /// the resolution that built it (`MessageBubble.resolvedRichVerdict`).
    let richVerdictIsKnown: Bool
    let fullTextContent: String?
    let fallbackPreviewText: String?
    let sharedDocumentLinks: [SharedDocumentLink]
    let hasLoadedContent: Bool
    /// Whether MessageBubble shows any attachments above this content: its filtered set, not
    /// `message.attachments` (signature and non-displayable inline images are filtered out).
    let hasDisplayableAttachments: Bool
    let forwardedDisplayContent: ForwardedMessageDisplayContent?
    let fullEmailOpener: any FullEmailOpening
    let originalEmailSourceWarmer: any OriginalEmailSourceWarming
    let htmlSourceSignaturer: any HTMLSourceSignaturing
    let onOpenFullMessage: (EmailReaderOpenSource) -> Void
    /// Non-nil for an outgoing row `FailedSendRecoveryPolicy` offers recovery for ("Not sent",
    /// "Delivery unknown"): tapping the bubble then calls `onSendRecoveryTap`, which presents that
    /// dialog instead of the email reader, and the prompt supplies the bubble's VoiceOver hint.
    let sendRecoveryPrompt: FailedSendRecoveryPolicy.Prompt?
    let onSendRecoveryTap: () -> Void

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
        } else if MessageDisplayPolicy.showsTextLoadingPlaceholder(
            hasLoadedContent: hasLoadedContent,
            routing: displayInput,
            richVerdictIsKnown: richVerdictIsKnown,
            chatPreviewText: message.chatPreviewText,
            hasDisplayableAttachments: hasDisplayableAttachments
        ) {
            // Avoid flashing raw/partial HTML-derived text while async content detection is still
            // running. Rows whose stored preview is their final text are exempt (see the policy):
            // the user's own rows, whose pill flickered on every reply's echo remount, and
            // incoming rows that no outcome of the load can route to a preview card, whose pill
            // → bubble swap grew the transcript on every fresh mount. So are the user's
            // attachments-only rows, whose pill vanished into nothing once the load finished. An
            // incoming row the load can still route to a card keeps the pill whatever it stores:
            // its text would be shown and then replaced by the card. That now takes a row with
            // no known rich-content verdict; with one, the load's routing is already known.
            loadingPlaceholder
        } else {
            if let text = resolvedVisibleText, !text.isEmpty {
                textAndSharedDocumentContent(text: text)
            } else if !sharedDocumentLinks.isEmpty {
                sharedDocumentCards
            } else if !hasDisplayableAttachments {
                // Nothing else is visible - show a placeholder that opens the original on tap.
                // An HTML body with no extractable text lands here too, deliberately: no
                // "View original" bubble. Gated on the displayed attachments, not
                // `message.attachments`: a message whose only attachments are filtered out
                // (e.g. signature images) would otherwise show nothing to see or tap.
                noContentPlaceholder
            }
            // If attachments are displayed but there is no text, show nothing (attachments are the
            // content; any original stays reachable from the long-press menu)
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

        switch MessageOriginalEmailOpenPolicy.textBubbleTap(
            hasOriginalEmailContent: message.hasOriginalEmailContent,
            offersSendRecovery: sendRecoveryPrompt != nil
        ) {
        case .sendRecovery:
            // A failed reply's natural tap used to open the reader on the user's own unsent text.
            // The original stays reachable from the long-press menu's "View original email".
            Button {
                onSendRecoveryTap()
            } label: {
                textBubbleBody(displayText)
            }
            .buttonStyle(.plain)
            // `.sendRecovery` implies a prompt; the fallback is unreachable.
            .accessibilityHint(sendRecoveryPrompt?.accessibilityHint ?? "")
        case .originalEmail:
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
        case .none:
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

    /// The whole bubble (lead-in note and forwarded card) opens the original, like a text bubble —
    /// and, like a text bubble, presents the failed-send dialog instead for an unsent forward.
    @ViewBuilder
    private func forwardedTextContent(for content: ForwardedMessageDisplayContent) -> some View {
        Button {
            if sendRecoveryPrompt != nil {
                onSendRecoveryTap()
            } else {
                openOriginalEmail(source: .previewCard)
            }
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
        .accessibilityHint(sendRecoveryPrompt?.accessibilityHint ?? "Opens the full original email")
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
    /// Whether tapping a text bubble opens the original email. The bubble itself is the inline
    /// way in — there is deliberately no "View original" control beside it — so it opens whenever
    /// there is original content behind it, the same gate as the long-press menu's
    /// "View original email". (Rich preview cards and forwarded bubbles always open on tap.)
    static func textBubbleTapOpensOriginal(hasOriginalEmailContent: Bool) -> Bool {
        hasOriginalEmailContent
    }

    /// What tapping a text bubble does.
    enum TextBubbleTap: Equatable {
        /// Presents the failed-send dialog (`FailedSendRecoveryPolicy`).
        case sendRecovery
        case originalEmail
        /// Not a button; the text stays selectable.
        case none
    }

    /// Send recovery wins over opening the original: an optimistic row always has original
    /// content (its typed `bodyText`), so a "Not sent" bubble's tap would otherwise open the
    /// reader on the user's own unsent text instead of offering a way to fix it.
    static func textBubbleTap(hasOriginalEmailContent: Bool, offersSendRecovery: Bool) -> TextBubbleTap {
        if offersSendRecovery { return .sendRecovery }
        return textBubbleTapOpensOriginal(hasOriginalEmailContent: hasOriginalEmailContent)
            ? .originalEmail
            : .none
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
