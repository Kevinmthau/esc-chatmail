import Foundation

extension ChatBubbleTextProcessor {
    struct HTMLProcessingCleanupResult {
        let html: String
        let applyPlainTextQuoteRemoval: Bool
        /// Rescue modes must retain content that signature cleanup removed.
        let applyTrailingContactSignatureRemoval: Bool
        /// True only for the containers-only rescue: that mode skips marker
        /// truncation, so a leftover attribution line must be dropped at the
        /// text level. The fuller modes already truncate attributions in the DOM,
        /// and running the line filter on their output risks deleting legitimate
        /// prose.
        let stripStandaloneQuoteAttributionLines: Bool
    }

    // Retained tables, headings, lists and media carry context lost by text extraction.
    // Leave those documents to DOM cleanup, including its content-preservation guards.
    private static let textSignatureProtectedStructurePattern = try? NSRegularExpression(
        pattern: #"<\s*(?:table|thead|tbody|tfoot|tr|td|th|h[1-6]|ul|ol|li|dl|dt|dd|figure|figcaption|img|picture|svg|video|audio|object|embed|iframe|canvas)\b|\b(?:src|srcset|background|poster)\s*=|cid:|url\s*\("#,
        options: [.caseInsensitive]
    )

    static func extractPlainTextFromHTML(
        from html: String,
        decodeHTMLEntities: Bool = false,
        formatSignOffLineBreaks: Bool = true,
        applyPlainTextQuoteRemoval: Bool = false,
        stripStandaloneQuoteAttributionLines: Bool = false,
        applyTrailingContactSignatureRemoval: Bool = false
    ) -> String? {
        // HTML compatibility fallback for records missing chatPreviewText. The
        // extraction itself is DOM-backed; the plain-text quote cleanup below is
        // only used when HTML quote cleanup leaves no meaningful content.
        let extracted = TextProcessing.extractPlainText(from: html)
        guard !extracted.isEmpty else { return nil }

        let decoded = decodeHTMLEntities ? HTMLEntityDecoder.decode(extracted) : extracted
        let textBeforeUnwrap = applyPlainTextQuoteRemoval
            ? decoded
            : removeConsecutivePlainTextQuoteLines(from: decoded)
        let hasProtectedStructure = textSignatureProtectedStructurePattern?.firstMatch(
            in: html,
            range: NSRange(html.startIndex..., in: html)
        ) != nil
        let contactCleaned = applyTrailingContactSignatureRemoval && !hasProtectedStructure
            ? PlainTextSignatureRemover.removeTrailingContactSignature(from: textBeforeUnwrap)
            : textBeforeUnwrap
        let unwrapped = TextProcessing.unwrapEmailLineBreaks(from: contactCleaned)
        let quoteRemoved: String
        if applyPlainTextQuoteRemoval {
            quoteRemoved = PlainTextQuoteRemover.extractQuotes(from: unwrapped).mainContent
        } else {
            let headerRemoved = removePlainTextHeaderQuoteBlocks(from: unwrapped)
            let attributionRemoved = stripStandaloneQuoteAttributionLines
                ? removeStandaloneQuoteAttributionLines(from: headerRemoved)
                : headerRemoved
            quoteRemoved = removeResidualHTMLTextQuoteMarkers(from: attributionRemoved)
        }
        let formatted = formatSignOffLineBreaks
            ? TextProcessing.formatSignOffLineBreaks(in: quoteRemoved)
            : quoteRemoved
        let trimmed = formatted.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func removeConsecutivePlainTextQuoteLines(from text: String) -> String {
        let lines = text.components(separatedBy: .newlines)
        guard lines.count > 1 else { return text }

        var consecutiveQuoteLineCount = 0
        for index in lines.indices {
            let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix(">") {
                consecutiveQuoteLineCount += 1
                if consecutiveQuoteLineCount >= 2 {
                    var firstQuoteLineIndex = index - consecutiveQuoteLineCount + 1
                    if firstQuoteLineIndex > 0 {
                        let precedingLine = lines[firstQuoteLineIndex - 1].trimmingCharacters(in: .whitespaces)
                        if isHTMLTextQuoteAttributionLine(precedingLine) {
                            firstQuoteLineIndex -= 1
                        }
                    }
                    return lines[..<firstQuoteLineIndex].joined(separator: "\n")
                }
            } else {
                consecutiveQuoteLineCount = 0
            }
        }

        return text
    }

    /// Drops lines that are ONLY a quote attribution ("On …, Olga wrote:")
    /// without truncating anything after them. The containers-only cleanup
    /// removes the quoted blockquote but leaves its attribution line behind;
    /// truncating at it (the residual-marker behavior) would rediscard the
    /// content that follows.
    private static func removeStandaloneQuoteAttributionLines(from text: String) -> String {
        let lines = text.components(separatedBy: .newlines)
        guard lines.count > 1 else { return text }

        let kept = lines.filter { line in
            !isStandaloneQuoteAttributionLine(line.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        guard kept.count != lines.count else { return text }
        return kept.joined(separator: "\n")
    }

    /// A genuine attribution needs more than the "wrote:" suffix — prose like
    /// "Here is what I wrote:" must survive. Real client attributions start
    /// with a date preposition ("On …", "Am …") or embed the quoted sender's
    /// address.
    private static func isStandaloneQuoteAttributionLine(_ line: String) -> Bool {
        guard isHTMLTextQuoteAttributionLine(line) else { return false }

        let lowercased = line.lowercased()
        let datePrefixes = ["on ", "am ", "le ", "el ", "il ", "em ", "op "]
        if datePrefixes.contains(where: { lowercased.hasPrefix($0) }) {
            return true
        }
        return line.contains("@") || line.contains("<")
    }

    private static func isHTMLTextQuoteAttributionLine(_ text: String) -> Bool {
        let lowercased = text.lowercased()
        let attributionSuffixes = [
            "wrote:", "schrieb:", "a écrit :", "a écrit:", "escribió:",
            "ha scritto:", "escreveu:", "schreef:"
        ]
        return attributionSuffixes.contains(where: { lowercased.hasSuffix($0) })
    }

    private static let residualHTMLTextQuoteMarkerPatterns: [NSRegularExpression] = {
        let rawPatterns = [
            #"(?im)(?:^|\n)\s*begin forwarded message:\s*"#,
            #"(?im)(?:^|\n)\s*-{2,}\s*forwarded message\b[^\n]*"#,
            #"(?im)\s-{2,}\s*forwarded message\b[^\n]*"#,
            #"(?im)(?:^|\n)\s*-{2,}\s*original message\s*-{2,}[^\n]*"#,
            #"(?im)(?:^|\n)\s*Am .{1,200}? schrieb .{1,120}\s*:\s*"#,
            #"(?im)(?:^|\n)\s*Le .{1,200}? a écrit\s*:\s*"#,
            #"(?im)(?:^|\n)\s*El .{1,200}? escribió\s*:\s*"#,
            #"(?im)(?:^|\n)\s*Il .{1,200}? ha scritto\s*:\s*"#,
            #"(?im)(?:^|\n)\s*Em .{1,200}? escreveu\s*:\s*"#,
            #"(?im)(?:^|\n)\s*Op .{1,200}? schreef .{1,120}\s*:\s*"#
        ]
        return rawPatterns.compactMap { try? NSRegularExpression(pattern: $0, options: []) }
    }()

    private static func removeResidualHTMLTextQuoteMarkers(from text: String) -> String {
        let range = NSRange(location: 0, length: text.utf16.count)
        let earliestMatch = residualHTMLTextQuoteMarkerPatterns
            .compactMap { pattern in
                pattern.firstMatch(in: text, options: [], range: range)
            }
            .min { lhs, rhs in
                if lhs.range.location == rhs.range.location {
                    return lhs.range.length < rhs.range.length
                }
                return lhs.range.location < rhs.range.location
            }

        guard let earliestMatch,
              let matchRange = Range(earliestMatch.range, in: text) else {
            return text
        }

        return String(text[..<matchRange.lowerBound])
    }

    private static let htmlTextFromHeaderPrefixesLowercased = QuoteHeaderPatterns.fromPrefixes

    private static let htmlTextToHeaderPrefixesLowercased = QuoteHeaderPatterns.toPrefixes

    private static let htmlTextSentOrDateHeaderPrefixesLowercased = QuoteHeaderPatterns.sentOrDatePrefixes

    private static let htmlTextEmailPattern = EmailPatterns.address

    private static func removePlainTextHeaderQuoteBlocks(from text: String) -> String {
        let lines = text.components(separatedBy: .newlines)
        guard lines.count > 1 else { return text }

        var lineStartOffsets: [Int] = []
        lineStartOffsets.reserveCapacity(lines.count)
        var runningOffset = 0
        for (index, line) in lines.enumerated() {
            lineStartOffsets.append(runningOffset)
            runningOffset += line.count
            if index < lines.count - 1 {
                runningOffset += 1
            }
        }

        for index in lines.indices {
            let trimmed = lines[index].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }

            let lowercased = trimmed.lowercased()
            guard htmlTextFromHeaderPrefixesLowercased.contains(where: { lowercased.hasPrefix($0) }) else {
                continue
            }

            guard index > 0,
                  lines[index - 1].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                continue
            }

            var sawTo = false
            var sawSentOrDate = false
            var sawEmailAddress = containsHTMLTextEmailAddress(trimmed)
            let upperBound = min(lines.count, index + 24)

            if index + 1 < upperBound {
                for candidateIndex in (index + 1)..<upperBound {
                    let candidate = lines[candidateIndex].trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !candidate.isEmpty else { continue }

                    let candidateLower = candidate.lowercased()
                    if htmlTextToHeaderPrefixesLowercased.contains(where: { candidateLower.hasPrefix($0) }) {
                        sawTo = true
                    }
                    if htmlTextSentOrDateHeaderPrefixesLowercased.contains(where: { candidateLower.hasPrefix($0) }) {
                        sawSentOrDate = true
                    }
                    if containsHTMLTextEmailAddress(candidate) {
                        sawEmailAddress = true
                    }

                    if sawTo && sawSentOrDate && sawEmailAddress,
                       let removalIndex = text.index(text.startIndex, offsetBy: lineStartOffsets[index], limitedBy: text.endIndex) {
                        return String(text[..<removalIndex])
                    }
                }
            }
        }

        return text
    }

    private static func containsHTMLTextEmailAddress(_ text: String) -> Bool {
        let range = NSRange(location: 0, length: text.utf16.count)
        return htmlTextEmailPattern?.firstMatch(in: text, options: [], range: range) != nil
    }

    static func cleanedHTMLForProcessing(_ html: String) -> HTMLProcessingCleanupResult {
        // quotedContainersOnly is the quote-first-reply rescue: when marker
        // truncation wipes the whole body (attribution + blockquote first,
        // content after), removing just the quoted containers keeps the
        // content that follows them.
        let fallback = HTMLCleanupFallback.cleanedHTML(
            from: html,
            modes: [.quotedAndSignatures, .quotedOnly, .quotedContainersOnly]
        )
        return HTMLProcessingCleanupResult(
            html: fallback.html,
            applyPlainTextQuoteRemoval: fallback.appliedMode == nil,
            applyTrailingContactSignatureRemoval: fallback.appliedMode == .quotedAndSignatures,
            stripStandaloneQuoteAttributionLines: fallback.appliedMode == .quotedContainersOnly
        )
    }
}
