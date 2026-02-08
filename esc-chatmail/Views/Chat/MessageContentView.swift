import SwiftUI

/// Displays the content portion of a message bubble.
/// Handles rich HTML, plain text, attachments, and empty states.
struct MessageContentView: View {
    /// Pre-compiled regex to detect actual HTML tags (not math expressions like 5 < 10 > 3)
    private static let htmlTagPattern: NSRegularExpression? = {
        try? NSRegularExpression(
            pattern: "<[a-zA-Z][a-zA-Z0-9]*(?:\\s[^>]*)?>|</[a-zA-Z][a-zA-Z0-9]*>",
            options: []
        )
    }()
    let message: Message
    let style: MessageBubbleStyle
    let showHTMLPreview: Bool
    let fullTextContent: String?
    let hasLoadedContent: Bool
    @Binding var showingHTMLView: Bool

    private var htmlContentHandler: HTMLContentHandler { HTMLContentHandler.shared }

    var body: some View {
        if showHTMLPreview {
            // Show HTML preview for newsletters/forwarded emails.
            // For forwards, also show the user's lead-in text as a normal chat bubble.
            VStack(alignment: message.isFromMe ? .trailing : .leading, spacing: 8) {
                if let intro = forwardedIntroText, !intro.isEmpty {
                    textBubble(text: intro, includeViewMore: false)
                }

                EmailContentSection(
                    message: message,
                    showingHTMLView: $showingHTMLView
                )
            }
            .frame(maxWidth: style.maxBubbleWidth, alignment: message.isFromMe ? .trailing : .leading)
        } else {
            // Personal emails: Show as chat bubbles with text
            textContent
        }
    }

    @ViewBuilder
    private var textContent: some View {
        // Avoid flashing raw/partial HTML-derived text while async content detection is still running.
        if message.hasHTMLSource && !hasLoadedContent {
            loadingPlaceholder
        } else {
            // Fallback chain:
            // 1. fullTextContent - Async-loaded processed text (best quality, but may not be ready on first render)
            // 2. processedText(bodyText) - Full body text with processing (immediate, full content)
            // 3. processedText(snippet) - Gmail API snippet with processing (truncated, rarely used)
            // 4. message.snippet - Raw truncated snippet (last resort)
            // Note: We skip message.cleanedSnippet because TextSnippetCreator destroys all newlines
            if let text = fullTextContent ?? processedText(message.bodyText) ?? processedText(message.snippet) ?? message.snippet, !text.isEmpty {
                textBubble(text: text)
            } else if message.hasHTMLSource {
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
    }

    private var loadingPlaceholder: some View {
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

    @ViewBuilder
    private func textBubble(text: String, includeViewMore: Bool = true) -> some View {
        let (displayText, wasTruncated) = truncatedText(text, lineLimit: style.textLineLimit)
        let showViewMore = includeViewMore && (showHTMLPreview || wasTruncated)

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

    /// Returns user-written lead-in text for forwarded emails, excluding forwarded content.
    private var forwardedIntroText: String? {
        guard message.isForwardedEmail else { return nil }

        // Prefer raw plain-text body for forwards so we can split exactly at the forward marker.
        if let bodyText = message.bodyText,
           let intro = extractForwardIntro(from: bodyText) {
            return intro
        }

        // Fallback: only use a short snippet-like value; avoid showing large forwarded content.
        let fallback = (message.snippet ?? fullTextContent)?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard let fallback, !fallback.isEmpty, fallback.count <= 280 else {
            return nil
        }
        return fallback
    }

    private func extractForwardIntro(from text: String) -> String? {
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        let markers = [
            "---------- Forwarded message ---------",
            "---------- Forwarded message ----------",
            "----- Forwarded message -----",
            "Begin forwarded message:",
            "-----Original Message-----",
            "------ Original Message ------"
        ]

        var intro = normalized
        for marker in markers {
            if let range = normalized.range(of: marker, options: [.caseInsensitive]) {
                intro = String(normalized[..<range.lowerBound])
                break
            }
        }

        let trimmed = intro.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Processes text while preserving paragraph structure and decoding HTML entities
    /// Uses the same processing as ProcessedTextCache but preserves line breaks
    /// (unlike cleanedSnippet which destroyed all newlines for conversation list previews)
    private func processedText(_ text: String?) -> String? {
        guard let text = text else { return nil }

        var processed = text
        var alreadyStrippedQuotes = false

        // If text contains actual HTML tags, strip HTML quotes first
        // This ensures consistency with ProcessedTextCache which also uses HTMLQuoteRemover
        // Uses proper regex to avoid false positives on math like "5 < 10 > 3"
        if Self.containsHTMLTags(text) {
            // Always extract plain text from HTML content
            if let strippedHTML = HTMLQuoteRemover.removeQuotes(from: text) {
                processed = TextProcessing.extractPlainText(from: strippedHTML)
                alreadyStrippedQuotes = true
            } else {
                // HTMLQuoteRemover returned nil (empty result) - the HTML was entirely quotes
                // Extract plain text and let plain text quote stripping handle it
                processed = TextProcessing.extractPlainText(from: text)
                // Note: alreadyStrippedQuotes stays false so we still strip plain text quotes
                // This handles the case where HTML quote removal failed but there may still
                // be plain text quote markers in the extracted content
            }
        }

        let decoded = HTMLEntityDecoder.decode(processed)
        let unwrapped = TextProcessing.unwrapEmailLineBreaks(from: decoded)

        // Only strip plain text quotes if we haven't already stripped HTML quotes
        let quoteStripped = alreadyStrippedQuotes ? unwrapped : TextProcessing.stripQuotedText(from: unwrapped)
        // Always strip signatures, even when HTML quotes were removed upstream
        let signatureStripped = TextProcessing.stripSignatures(from: quoteStripped)
        // Format sign-off line breaks (handles "...help. Regards, Kevin" → proper line breaks)
        let result = TextProcessing.formatSignOffLineBreaks(in: signatureStripped)
        return result.isEmpty ? nil : result
    }

    /// Checks if text contains actual HTML tags (not math expressions)
    private static func containsHTMLTags(_ text: String) -> Bool {
        guard let regex = htmlTagPattern else {
            // Fallback to simple check if regex compilation failed
            return text.contains("<") && text.contains(">")
        }
        let range = NSRange(location: 0, length: text.utf16.count)
        return regex.firstMatch(in: text, options: [], range: range) != nil
    }
}
