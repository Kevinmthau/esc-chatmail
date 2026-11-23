import Foundation

enum ChatBubbleTextInputKind: Sendable {
    case html
    case plainText
    case autoDetectHTML
}

struct ChatBubbleTextProcessorOptions: Sendable {
    let inputKind: ChatBubbleTextInputKind
    let sanitizeRawEmailSource: Bool
    let decodeHTMLEntities: Bool
    let formatSignOffLineBreaks: Bool
    let classifyRichContent: Bool

    init(
        inputKind: ChatBubbleTextInputKind,
        sanitizeRawEmailSource: Bool = true,
        decodeHTMLEntities: Bool = true,
        formatSignOffLineBreaks: Bool = true,
        classifyRichContent: Bool = false
    ) {
        self.inputKind = inputKind
        self.sanitizeRawEmailSource = sanitizeRawEmailSource
        self.decodeHTMLEntities = decodeHTMLEntities
        self.formatSignOffLineBreaks = formatSignOffLineBreaks
        self.classifyRichContent = classifyRichContent
    }
}

struct ChatBubbleTextProcessingResult: Sendable {
    let mainText: String?
    let quotedParts: [QuotedPart]
    let hasRichContent: Bool

    init(mainText: String?, quotedParts: [QuotedPart] = [], hasRichContent: Bool = false) {
        self.mainText = mainText
        self.quotedParts = quotedParts
        self.hasRichContent = hasRichContent
    }
}

/// Derives chat-bubble text from HTML or plain-text email content for the
/// compatibility path (messages without a stored `chatPreviewText`) and for
/// ingest-time preview derivation.
///
/// Split across:
/// - `ChatBubbleTextProcessor.swift` — option/result types and the HTML vs
///   plain-text dispatch.
/// - `ChatBubbleTextProcessor+HTMLTextExtraction.swift` — the HTML cleanup
///   degradation chain and HTML-to-text quote/attribution cleanup.
///
/// Rich-content classification lives in `RichContentClassifier`; loading a
/// stored message body and its cache source signature lives in
/// `MessageBubbleContentSource`.
enum ChatBubbleTextProcessor {
    // Detects genuine HTML tags while avoiding false positives on expressions like `5 < 10 > 3`.
    private static let htmlTagPattern: NSRegularExpression? = {
        try? NSRegularExpression(
            pattern: "<[a-zA-Z][a-zA-Z0-9]*(?:\\s[^>]*)?>|</[a-zA-Z][a-zA-Z0-9]*>|<[a-zA-Z][a-zA-Z0-9]*(?:\\s[^>\\n]*)?$",
            options: []
        )
    }()

    /// The most text, in UTF-16 units, the bubble derivation reads from one
    /// body (`cappedExtractedText`).
    static let extractedTextUTF16Limit = 65_536

    /// `text`, or its first `extractedTextUTF16Limit` UTF-16 units, cut back
    /// to the last line break in their second half, or to a character
    /// boundary where that half has none (so a short first line before one
    /// long one does not leave the bubble nearly empty).
    ///
    /// The quote and signature passes after extraction read all of the text,
    /// several of them more than once, and nothing bounded a body's size: a
    /// megabyte log stalled the sync batch it was in. So derivation reads at
    /// most this much, and the bubble of a longer body ends there (it has no
    /// line limit; the original email still opens whole). The cap is a pure function of
    /// the extracted text, so ingest, both `ChatPreviewRepair` passes and the
    /// bubble loader, which all derive through here, still agree. Text under
    /// it derives exactly as before, and no stored verdict reads text past it
    /// (the verdict reads the HTML), so there is no `CacheVersioning` bump: a
    /// preview already stored for a longer body keeps the text it has. It
    /// caps extracted text only:
    /// never the HTML (the rich-content verdict reads that) nor the stored
    /// `bodyText` or `cleanedSnippet`, and it is not inside the shared
    /// primitives (`unwrapEmailLineBreaks`, `PlainTextQuoteRemover`), which
    /// also build the reader and outgoing reply quotes.
    static func cappedExtractedText(_ text: String) -> String {
        let utf16 = text.utf16
        guard utf16.count > extractedTextUTF16Limit else { return text }
        let nsText = text as NSString
        let cut = nsText.rangeOfComposedCharacterSequence(at: extractedTextUTF16Limit).location
        let prefix = nsText.substring(to: cut) as NSString
        let secondHalf = NSRange(location: cut / 2, length: cut - cut / 2)
        let lastLineBreak = prefix.range(of: "\n", options: .backwards, range: secondHalf)
        if lastLineBreak.location != NSNotFound {
            return prefix.substring(to: lastLineBreak.location)
        }
        return prefix as String
    }

    static func process(
        content: String?,
        options: ChatBubbleTextProcessorOptions
    ) -> ChatBubbleTextProcessingResult {
        guard let content, !content.isEmpty else {
            return ChatBubbleTextProcessingResult(mainText: nil, quotedParts: [], hasRichContent: false)
        }

        let inputKind = resolvedInputKind(for: content, requestedKind: options.inputKind)
        if inputKind == .html {
            return processHTML(
                content,
                decodeHTMLEntities: options.decodeHTMLEntities,
                formatSignOffLineBreaks: options.formatSignOffLineBreaks,
                classifyRichContent: options.classifyRichContent
            )
        }

        return processPlainText(
            content,
            sanitizeRawEmailSource: options.sanitizeRawEmailSource,
            decodeHTMLEntities: options.decodeHTMLEntities,
            formatSignOffLineBreaks: options.formatSignOffLineBreaks
        )
    }

    private static func resolvedInputKind(
        for content: String,
        requestedKind: ChatBubbleTextInputKind
    ) -> ChatBubbleTextInputKind {
        switch requestedKind {
        case .autoDetectHTML:
            containsHTMLTags(content) ? .html : .plainText
        case .html, .plainText:
            requestedKind
        }
    }

    static func htmlCompatibilityFallback(
        from html: String?,
        classifyRichContent: Bool
    ) -> ChatBubbleTextProcessingResult {
        process(
            content: html,
            options: ChatBubbleTextProcessorOptions(
                inputKind: .html,
                sanitizeRawEmailSource: false,
                decodeHTMLEntities: true,
                formatSignOffLineBreaks: true,
                classifyRichContent: classifyRichContent
            )
        )
    }

    static func plainTextOnlyFallback(
        from text: String?,
        sanitizeRawEmailSource: Bool = true,
        decodeHTMLEntities: Bool = true
    ) -> ChatBubbleTextProcessingResult {
        process(
            content: text,
            options: ChatBubbleTextProcessorOptions(
                inputKind: .plainText,
                sanitizeRawEmailSource: sanitizeRawEmailSource,
                decodeHTMLEntities: decodeHTMLEntities,
                formatSignOffLineBreaks: true,
                classifyRichContent: false
            )
        )
    }

    static func legacyAutoDetectedFallback(
        from text: String?,
        sanitizeRawEmailSource: Bool = true,
        classifyRichContent: Bool
    ) -> ChatBubbleTextProcessingResult {
        process(
            content: text,
            options: ChatBubbleTextProcessorOptions(
                inputKind: .autoDetectHTML,
                sanitizeRawEmailSource: sanitizeRawEmailSource,
                decodeHTMLEntities: true,
                formatSignOffLineBreaks: true,
                classifyRichContent: classifyRichContent
            )
        )
    }

    private static func processHTML(
        _ html: String,
        decodeHTMLEntities: Bool,
        formatSignOffLineBreaks: Bool,
        classifyRichContent: Bool
    ) -> ChatBubbleTextProcessingResult {
        // Strip quoted/signature content from HTML first. If that pass removes too much
        // (e.g., transactional templates), fall back to quote-only cleanup or original HTML.
        let cleanup = cleanedHTMLForProcessing(html)

        var plainText = extractPlainTextFromHTML(
            from: cleanup.html,
            decodeHTMLEntities: decodeHTMLEntities,
            formatSignOffLineBreaks: formatSignOffLineBreaks,
            applyPlainTextQuoteRemoval: cleanup.applyPlainTextQuoteRemoval,
            stripStandaloneQuoteAttributionLines: cleanup.stripStandaloneQuoteAttributionLines,
            applyTrailingContactSignatureRemoval: cleanup.applyTrailingContactSignatureRemoval
        )

        if plainText == nil {
            plainText = extractPlainTextFromHTML(
                from: html,
                decodeHTMLEntities: decodeHTMLEntities,
                formatSignOffLineBreaks: formatSignOffLineBreaks,
                applyPlainTextQuoteRemoval: true
            )
        }

        if cleanup.applyTrailingContactSignatureRemoval, let currentText = plainText {
            plainText = RepeatedSignatureRemover.removeSignature(from: currentText) {
                // Only project the source for a surviving, corroborated contact block.
                // History is evidence for preview cleanup; canonical HTML remains untouched.
                let sourceText = cappedExtractedText(TextProcessing.extractPlainText(from: html))
                return PlainTextQuoteRemover.extractQuotes(from: sourceText, removingSignature: false)
                    .quotedParts.map(\.text).joined(separator: "\n")
            }
        }

        let hasRichContent = classifyRichContent ? RichContentClassifier.hasGenuineRichContent(cleanup.html) : false
        return ChatBubbleTextProcessingResult(
            mainText: plainText,
            quotedParts: [],
            hasRichContent: hasRichContent
        )
    }

    private static func processPlainText(
        _ text: String,
        sanitizeRawEmailSource: Bool,
        decodeHTMLEntities: Bool,
        formatSignOffLineBreaks: Bool
    ) -> ChatBubbleTextProcessingResult {
        // Legacy/plain-text-only fallback. Normal chat bubbles should use the
        // persisted Message.chatPreviewText and avoid this quote/signature path.
        var processed = text
        if sanitizeRawEmailSource {
            processed = RawEmailSourceSanitizer.extractDisplayText(from: processed)
        }

        if decodeHTMLEntities {
            processed = HTMLEntityDecoder.decode(processed)
        }
        processed = cappedExtractedText(processed)

        let unwrapped = TextProcessing.unwrapEmailLineBreaks(from: processed)
        let extractionResult = PlainTextQuoteRemover.extractQuotes(from: unwrapped)
        let mainContent = formatSignOffLineBreaks
            ? TextProcessing.formatSignOffLineBreaks(in: extractionResult.mainContent)
            : extractionResult.mainContent
        let trimmed = mainContent.trimmingCharacters(in: .whitespacesAndNewlines)

        return ChatBubbleTextProcessingResult(
            mainText: trimmed.isEmpty ? nil : trimmed,
            quotedParts: extractionResult.quotedParts,
            hasRichContent: false
        )
    }

    static func containsHTMLTags(_ text: String) -> Bool {
        guard let regex = htmlTagPattern else {
            return text.contains("<") && text.contains(">")
        }
        let range = NSRange(location: 0, length: text.utf16.count)
        return regex.firstMatch(in: text, options: [], range: range) != nil
    }
}
