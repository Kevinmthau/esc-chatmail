import SwiftUI

/// Displays the content portion of a message bubble.
/// Handles rich HTML, plain text, attachments, and empty states.
struct MessageContentView: View {
    let message: Message
    let style: MessageBubbleStyle
    let showHTMLPreview: Bool
    let fullTextContent: String?
    let hasLoadedContent: Bool
    @Binding var showingHTMLView: Bool

    var body: some View {
        if showHTMLPreview {
            // Show HTML preview for newsletters/forwarded emails.
            // For forwards, also show the user's lead-in text as a normal chat bubble.
            VStack(alignment: message.isFromMe ? .trailing : .leading, spacing: 8) {
                if let intro = forwardedIntroText, !intro.isEmpty {
                    textBubble(text: intro)
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
        showingHTMLView = true
    }

    /// Returns user-written lead-in text for forwarded emails, excluding forwarded content.
    private var forwardedIntroText: String? {
        guard message.isForwardedEmail else { return nil }

        // Prefer raw plain-text body for forwards so we can split exactly at the forward marker.
        if let bodyText = message.bodyText,
           let intro = extractForwardIntro(from: bodyText),
           let cleanedIntro = cleanForwardedIntro(intro) {
            return cleanedIntro
        }

        // Fallback: only use a short snippet-like value; avoid showing large forwarded content.
        guard let rawFallback = message.snippet ?? fullTextContent,
              let fallback = cleanForwardedIntro(rawFallback) else {
            return nil
        }

        guard fallback.count <= 280 else {
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

    private func cleanForwardedIntro(_ text: String) -> String? {
        let sanitized = RawEmailSourceSanitizer.extractDisplayText(from: text)
        let decoded = HTMLEntityDecoder.decode(sanitized)
        let unwrapped = TextProcessing.unwrapEmailLineBreaks(from: decoded)
        let signatureStripped = TextProcessing.stripSignatures(from: unwrapped)
        let formatted = TextProcessing.formatSignOffLineBreaks(in: signatureStripped)
        let trimmed = formatted.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Processes text while preserving paragraph structure and decoding HTML entities
    /// Uses the same processing as ProcessedTextCache but preserves line breaks
    /// (unlike cleanedSnippet which destroyed all newlines for conversation list previews)
    private func processedText(_ text: String?) -> String? {
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
