import Foundation

/// Legacy/plain-text-only fallback for removing quoted text and signatures.
/// Normal chat bubbles should use persisted Message.chatPreviewText; this remains
/// for true plain-text-only emails and old records missing chatPreviewText.
enum PlainTextQuoteRemover {

    // MARK: - Quote Indicator Patterns

    /// Regex patterns that indicate quoted content (string form for reference)
    private static let quoteIndicatorPatternStrings = [
        // Time-based quotes - English
        // Require "On" at start of string or after newline to avoid mid-sentence matches
        // (e.g., "I need to reload on the Chablis" should not match)
        "(?:^|\\n)On .+ wrote:",
        "(?:^|\\n)On .+, .+ wrote:",
        "> On .+, at .+, .+ wrote:",
        // iOS/Apple Mail format: "On Jan 30, 2026 at 7:32 PM, Name" (wrote: may be on next line)
        "On [A-Z][a-z]+ \\d{1,2}, \\d{4} at \\d{1,2}:\\d{2}\\s*[AP]M,",

        // International quote patterns
        // German: "Am [date] schrieb [name]:"
        "Am .+ schrieb .+:",
        // French: "Le [date] [name] a écrit :" or "Le [date], [name] a écrit :"
        "Le .+ a écrit\\s*:",
        // Spanish: "El [date] [name] escribió:"
        "El .+ escribió:",
        // Italian: "Il [date] [name] ha scritto:"
        "Il .+ ha scritto:",
        // Portuguese: "Em [date] [name] escreveu:"
        "Em .+ escreveu:",
        // Dutch: "Op [date] schreef [name]:"
        "Op .+ schreef .+:",

        // Header-based quotes - Outlook style (uses "Sent:")
        "From: .+\nSent: .+\nTo: .+\nSubject: .+",
        "From: .+\nSent: .+\nTo: .+\nCc: .+\nSubject: .+",
        // Header-based quotes - Apple Mail style (uses "Date:")
        "From: .+\nDate: .+\nTo: .+\nSubject: .+",
        "From: .+\nDate: .+\nTo: .+\nCc: .+\nSubject: .+",
        "-----Original Message-----",
        "________________________________",

        // International header patterns
        // German
        "Von: .+\nGesendet: .+\nAn: .+\nBetreff: .+",
        // French
        "De\\s*: .+\nEnvoyé\\s*: .+\nÀ\\s*: .+\nObjet\\s*: .+",
        // Spanish
        "De: .+\nEnviado: .+\nPara: .+\nAsunto: .+",

        // Forward indicators - English
        "Begin forwarded message:",
        // Handles common dashed variants like:
        // "---------- Forwarded message ---------"
        // "---------- Forwarded message"
        // "----- Forwarded message -----"
        "(?:^|\\n)\\s*-{2,}\\s*Forwarded message\\b.*",
        // Handles soft-wrapped variants where the marker appears inline after intro text.
        "\\s-{2,}\\s*Forwarded message\\b.*",
        "---------- Forwarded message ---------",
        "------ Original Message ------",
        "(?:^|\\n)\\s*-{2,}\\s*Original Message\\b.*",

        // Forward indicators - International
        "Weitergeleitete Nachricht",   // German
        "Message transféré",            // French
        "Mensaje reenviado",            // Spanish
        "Messaggio inoltrato",          // Italian
        "Mensagem encaminhada",         // Portuguese
        "Doorgestuurd bericht",         // Dutch
    ]

    /// Pre-compiled regex patterns for performance (compiled once at class load)
    private static let compiledQuotePatterns: [NSRegularExpression] = {
        quoteIndicatorPatternStrings.compactMap {
            try? NSRegularExpression(pattern: $0, options: [.caseInsensitive])
        }
    }()

    // MARK: - Public API

    /// Removes quoted text from plain text email content
    /// - Parameter text: The plain text content to clean
    /// - Returns: Text with quotes and signatures removed, or nil if input was nil
    static func removeQuotes(from text: String?) -> String? {
        guard let text = text else { return nil }
        return extractQuotes(from: text).mainContent
    }

    /// Extracts quotes from plain text email content, returning both main content and quoted parts
    /// - Parameter text: The plain text content to process
    /// - Parameter removingSignature: Whether to remove trailing signature blocks from the main content
    /// - Returns: QuoteExtractionResult with main content and extracted quotes
    static func extractQuotes(from text: String, removingSignature: Bool = true) -> QuoteExtractionResult {
        var cleanText = text
        var quotedParts: [QuotedPart] = []
        var earliestQuoteIndex = cleanText.count
        var quoteAttribution: String?

        // Find earliest regex quote indicator and capture attribution
        let (patternIndex, attribution) = findEarliestPatternMatchWithAttribution(in: cleanText)
        if patternIndex < earliestQuoteIndex {
            earliestQuoteIndex = patternIndex
            quoteAttribution = attribution
        }

        // Check for consecutive ">" quote lines (also detects attribution lines before them)
        let (consecutiveIndex, consecutiveAttribution) = findConsecutiveQuoteLinesWithAttribution(in: cleanText)
        if consecutiveIndex < earliestQuoteIndex {
            earliestQuoteIndex = consecutiveIndex
            quoteAttribution = consecutiveAttribution
        }

        // Outlook/Apple-style header blocks can include blank lines and wrapped address lines.
        // Detect these structurally to avoid relying only on strict contiguous regex patterns.
        let (headerBlockIndex, headerBlockAttribution) = findHeaderBlockQuoteBoundaryWithAttribution(in: cleanText)
        if headerBlockIndex < earliestQuoteIndex {
            earliestQuoteIndex = headerBlockIndex
            quoteAttribution = headerBlockAttribution
        }

        // Extract quoted content before truncating
        if earliestQuoteIndex < cleanText.count {
            let endIndex = cleanText.index(cleanText.startIndex, offsetBy: earliestQuoteIndex)
            let quotedText = String(cleanText[endIndex...]).trimmingCharacters(in: .whitespacesAndNewlines)

            // Clean up the quoted text (remove quote markers like ">") and get nesting level
            let (cleanedQuote, nestingLevel) = cleanQuotedText(quotedText)
            if !cleanedQuote.isEmpty {
                quotedParts.append(QuotedPart(
                    text: cleanedQuote,
                    attribution: quoteAttribution,
                    nestingLevel: nestingLevel
                ))
            }

            cleanText = String(cleanText[..<endIndex])
        }

        // Remove signatures (optional).
        if removingSignature {
            cleanText = removeSignature(from: cleanText)
        }

        let mainContent = cleanText.trimmingCharacters(in: .whitespacesAndNewlines)
        return QuoteExtractionResult(mainContent: mainContent, quotedParts: quotedParts)
    }

    /// Removes email signatures and boilerplate from text
    /// - Parameter text: The text to clean
    /// - Returns: Text with signature removed
    static func removeSignature(from text: String) -> String {
        PlainTextSignatureRemover.removeSignature(from: text)
    }

    // MARK: - Private Helpers

    /// Finds the earliest match of any quote indicator pattern
    private static func findEarliestPatternMatch(in text: String) -> Int {
        return findEarliestPatternMatchWithAttribution(in: text).0
    }

    /// Finds the earliest match of any quote indicator pattern, returning both index and attribution
    private static func findEarliestPatternMatchWithAttribution(in text: String) -> (Int, String?) {
        var earliestIndex = text.count
        var attribution: String?
        let range = NSRange(location: 0, length: text.utf16.count)

        for regex in compiledQuotePatterns {
            if let match = regex.firstMatch(in: text, options: [], range: range),
               let matchRange = Range(match.range, in: text) {
                let index = text.distance(from: text.startIndex, to: matchRange.lowerBound)
                if index < earliestIndex {
                    earliestIndex = index
                    // Extract the matched text as attribution (e.g., "On Jan 1, John wrote:")
                    let matchedText = String(text[matchRange]).trimmingCharacters(in: .whitespacesAndNewlines)
                    let lowercased = matchedText.lowercased()
                    // Only use as attribution if it looks like a quote header
                    // Include international patterns
                    let quoteKeywords = [
                        // English
                        "wrote:", "from:", "forwarded message",
                        // German
                        "schrieb:", "von:", "weitergeleitete nachricht",
                        // French
                        "a écrit", "de:", "message transféré",
                        // Spanish
                        "escribió:", "mensaje reenviado",
                        // Italian
                        "ha scritto:", "messaggio inoltrato",
                        // Portuguese
                        "escreveu:", "mensagem encaminhada",
                        // Dutch
                        "schreef:", "doorgestuurd bericht"
                    ]
                    if quoteKeywords.contains(where: { lowercased.contains($0) }) {
                        attribution = matchedText
                    }
                }
            }
        }

        return (earliestIndex, attribution)
    }

    /// Pre-compiled regex for collapsing excessive newlines (performance optimization)
    private static let excessiveNewlinesPattern: NSRegularExpression? = {
        try? NSRegularExpression(pattern: "\n{3,}", options: [])
    }()

    // Pre-computed lowercased header prefixes for efficient case-insensitive matching
    // Using Set for O(1) lookup and automatic deduplication
    // Include both with and without space before colon for French patterns (some clients vary)
    private static let headerPrefixesLowercased: Set<String> = [
        // English
        "from:", "sent:", "to:", "subject:", "date:", "cc:",
        // German
        "von:", "gesendet:", "an:", "betreff:", "datum:",
        // French (both with and without space before colon - varies by client)
        "de:", "de :", "envoyé:", "envoyé :", "à:", "à :", "objet:", "objet :",
        // Spanish (de:, enviado: already in French/Portuguese)
        "para:", "asunto:",
        // Italian
        "da:", "inviato:", "oggetto:",
        // Portuguese (de:, enviado: already covered)
        "assunto:",
        // Dutch
        "van:", "verzonden:", "aan:", "onderwerp:"
    ]

    // Header groups used for structural quote boundary detection.
    private static let fromHeaderPrefixesLowercased = QuoteHeaderPatterns.fromPrefixes

    private static let toHeaderPrefixesLowercased = QuoteHeaderPatterns.toPrefixes

    private static let sentOrDateHeaderPrefixesLowercased = QuoteHeaderPatterns.sentOrDatePrefixes

    private static let subjectHeaderPrefixesLowercased = QuoteHeaderPatterns.subjectPrefixes

    // Pre-computed lowercased forward markers for efficient matching
    private static let forwardMarkersLowercased: [String] = [
        "-----original message-----",
        "begin forwarded message",
        "forwarded message",
        "________________________________",
        "weitergeleitete nachricht",
        "message transféré",
        "mensaje reenviado",
        "messaggio inoltrato",
        "mensagem encaminhada",
        "doorgestuurd bericht"
    ]

    /// Cleans up quoted text by removing quote markers and excessive whitespace
    /// Returns both the cleaned text and the maximum nesting level found
    private static func cleanQuotedText(_ text: String) -> (cleanedText: String, maxNestingLevel: Int) {
        let lines = text.components(separatedBy: .newlines)
        var cleanedLines: [String] = []
        var maxNestingLevel = 0

        for line in lines {
            // Count and strip leading ">" quote markers efficiently in a single pass
            let (cleanLine, lineNestingLevel) = stripQuoteMarkers(from: line)

            // Track maximum nesting level across all lines
            maxNestingLevel = max(maxNestingLevel, lineNestingLevel)

            // Skip empty lines early to avoid unnecessary lowercasing
            let trimmedLine = cleanLine.trimmingCharacters(in: .whitespaces)
            if trimmedLine.isEmpty {
                cleanedLines.append(cleanLine)
                continue
            }

            // Only lowercase once per line for all pattern matching
            let lowercased = cleanLine.lowercased()

            // Skip "On ... wrote:" patterns (English and international)
            if isQuoteAttributionLine(lowercased) {
                continue
            }

            // Skip header lines (From/Sent/To/Subject and international equivalents)
            if headerPrefixesLowercased.contains(where: { lowercased.hasPrefix($0) }) {
                continue
            }

            // Skip forward/original message markers
            if forwardMarkersLowercased.contains(where: { lowercased.contains($0) }) {
                continue
            }

            cleanedLines.append(cleanLine)
        }

        // Join and clean up excessive whitespace
        var result = cleanedLines.joined(separator: "\n")

        // Use pre-compiled regex for performance
        if let regex = excessiveNewlinesPattern {
            result = regex.stringByReplacingMatches(
                in: result,
                options: [],
                range: NSRange(location: 0, length: result.utf16.count),
                withTemplate: "\n\n"
            )
        } else {
            // Fallback if regex compilation failed
            result = result.replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
        }

        return (result.trimmingCharacters(in: .whitespacesAndNewlines), maxNestingLevel)
    }

    /// Strips leading ">" quote markers from a line and returns the clean line with nesting level
    /// Optimized to count markers and slice once instead of creating intermediate strings
    private static func stripQuoteMarkers(from line: String) -> (cleanedLine: String, nestingLevel: Int) {
        var index = line.startIndex
        var nestingLevel = 0

        // Count leading ">" markers and whitespace in a single pass
        while index < line.endIndex {
            let char = line[index]
            if char == ">" {
                nestingLevel += 1
                index = line.index(after: index)
                // Skip optional space after ">"
                if index < line.endIndex && line[index] == " " {
                    index = line.index(after: index)
                }
            } else if char == " " || char == "\t" {
                // Skip leading whitespace before quote markers
                index = line.index(after: index)
            } else {
                break
            }
        }

        // Return the substring from the current index
        let cleanedLine = String(line[index...])
        return (cleanedLine, nestingLevel)
    }

    /// Checks if a lowercased line is a quote attribution (e.g., "On Jan 1, John wrote:" or "John wrote:")
    private static func isQuoteAttributionLine(_ lowercased: String) -> Bool {
        let wrotePatterns = ["wrote:", "schrieb:", "a écrit", "escribió:", "ha scritto:", "escreveu:", "schreef:"]

        // Must contain a "wrote" pattern
        guard wrotePatterns.contains(where: { lowercased.contains($0) }) else {
            return false
        }

        // Accept if line ends with the "wrote" pattern (e.g., "John wrote:")
        // This handles simple attributions without date prefixes
        if wrotePatterns.contains(where: { lowercased.hasSuffix($0) }) {
            return true
        }

        // Also accept if has a date prefix pattern (e.g., "On Jan 1, John wrote:")
        let datePatterns = ["on ", "am ", "le ", "el ", "il ", "em ", "op "]
        return datePatterns.contains(where: { lowercased.contains($0) })
    }

    /// Finds the start of consecutive ">" quoted lines (2+ lines)
    /// Also looks backwards for attribution lines (e.g., "John wrote:") to include them
    /// Returns both the index and any detected attribution
    private static func findConsecutiveQuoteLinesWithAttribution(in text: String) -> (Int, String?) {
        let lines = text.components(separatedBy: .newlines)
        var consecutiveQuoteLines = 0

        for (index, line) in lines.enumerated() {
            let trimmedLine = line.trimmingCharacters(in: .whitespaces)
            if trimmedLine.hasPrefix(">") {
                consecutiveQuoteLines += 1
                // If we find 2+ consecutive quote lines, consider it quoted text
                if consecutiveQuoteLines >= 2 {
                    var firstQuoteLineIndex = index - consecutiveQuoteLines + 1
                    var attribution: String?

                    // Check if the line before the first quote line is an attribution
                    // (e.g., "John wrote:", "Hans schrieb:")
                    if firstQuoteLineIndex > 0 {
                        let precedingLineIndex = firstQuoteLineIndex - 1
                        let precedingLine = lines[precedingLineIndex].trimmingCharacters(in: .whitespaces)
                        if isAttributionLine(precedingLine.lowercased()) {
                            firstQuoteLineIndex = precedingLineIndex
                            attribution = precedingLine
                        }
                    }

                    let precedingLines = lines[0..<firstQuoteLineIndex]
                    let precedingText = precedingLines.joined(separator: "\n")
                    return (precedingText.count, attribution)
                }
            } else {
                consecutiveQuoteLines = 0
            }
        }

        return (text.count, nil)
    }

    /// Detects header-style quoted blocks with optional blank/wrapped lines, such as:
    /// From: Name
    /// <email@x.com>
    ///
    /// Sent: Saturday...
    /// To: Person...
    private static func findHeaderBlockQuoteBoundaryWithAttribution(in text: String) -> (Int, String?) {
        let lines = text.components(separatedBy: .newlines)
        guard !lines.isEmpty else { return (text.count, nil) }

        // Track absolute character offset for each line start.
        var lineStartOffsets: [Int] = []
        lineStartOffsets.reserveCapacity(lines.count)
        var runningOffset = 0
        for (index, line) in lines.enumerated() {
            lineStartOffsets.append(runningOffset)
            runningOffset += line.count
            if index < lines.count - 1 {
                runningOffset += 1 // newline separator
            }
        }

        let lookaheadLimit = 24

        for index in lines.indices {
            let trimmed = lines[index].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }

            let lowercased = trimmed.lowercased()
            guard fromHeaderPrefixesLowercased.contains(where: { lowercased.hasPrefix($0) }) else {
                continue
            }

            // Quote headers usually start after a blank line; skip mid-paragraph "From:" mentions.
            if index > 0 {
                let previousLine = lines[index - 1].trimmingCharacters(in: .whitespacesAndNewlines)
                if !previousLine.isEmpty {
                    continue
                }
            }

            var sawTo = false
            var sawSentOrDate = false
            var sawSubject = false
            let upperBound = min(lines.count, index + lookaheadLimit)

            if index + 1 < upperBound {
                for candidateIndex in (index + 1)..<upperBound {
                    let candidate = lines[candidateIndex].trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !candidate.isEmpty else { continue }

                    let candidateLower = candidate.lowercased()
                    if toHeaderPrefixesLowercased.contains(where: { candidateLower.hasPrefix($0) }) {
                        sawTo = true
                    }
                    if sentOrDateHeaderPrefixesLowercased.contains(where: { candidateLower.hasPrefix($0) }) {
                        sawSentOrDate = true
                    }
                    if subjectHeaderPrefixesLowercased.contains(where: { candidateLower.hasPrefix($0) }) {
                        sawSubject = true
                    }

                    if sawTo && (sawSentOrDate || sawSubject) {
                        return (lineStartOffsets[index], trimmed)
                    }
                }
            }
        }

        return (text.count, nil)
    }

    /// Checks if a line looks like a quote attribution (e.g., "John wrote:", "On Jan 1, Mary wrote:")
    /// This is used to extend quote boundaries to include attribution lines
    private static func isAttributionLine(_ lowercased: String) -> Bool {
        // Must end with a "wrote:" pattern (or international equivalent)
        let wrotePatterns = ["wrote:", "schrieb:", "a écrit :", "a écrit:", "escribió:", "ha scritto:", "escreveu:", "schreef:"]

        return wrotePatterns.contains(where: { lowercased.hasSuffix($0) })
    }
}
