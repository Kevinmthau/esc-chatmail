import Foundation

/// Removes quoted text blocks from HTML email content
/// Handles Gmail, Outlook, Apple Mail, and generic quote patterns
enum HTMLQuoteRemover {

    enum RemovalMode {
        case quotedOnly
        case quotedAndSignatures
    }

    // MARK: - Quote Patterns

    /// HTML quote block patterns to remove entirely (string form for reference)
    private static let quotedBlockPatternStrings = [
        // Gmail quote blocks (flexible class matching for multiple classes like "gmail_quote gmail_quote_container")
        "<div[^>]*class=\"[^\"]*gmail_quote[^\"]*\"[^>]*>.*?</div>",
        "<div[^>]*class=\"[^\"]*gmail_attr[^\"]*\"[^>]*>.*?</div>",
        "<blockquote[^>]*>.*?</blockquote>",

        // Outlook/Office 365
        "<div class=\"OutlookMessageHeader\">.*?</div>",

        // Apple Mail
        "<br><div><br><blockquote type=\"cite\">.*?</blockquote></div>",
        "<div class=\"AppleMailSignature\">.*?</div>",

        // Generic quoted sections
        "<div style=\"[^\"]*border-left:[^\"]*\">.*?</div>",
        "<!-- originalMessage -->.*?<!-- /originalMessage -->",
        "<div class=\"moz-cite-prefix\">.*?</div>",
    ]

    /// Signature/footer specific block patterns. These are removed only in
    /// `.quotedAndSignatures` mode.
    private static let signatureBlockPatternStrings = [
        // Email footers and boilerplate
        "<div[^>]*class=\"[^\"]*footer[^\"]*\"[^>]*>.*?</div>",
        "<table[^>]*class=\"[^\"]*footer[^\"]*\"[^>]*>.*?</table>",
        "<div[^>]*id=\"[^\"]*footer[^\"]*\"[^>]*>.*?</div>",

        // Social media and icon sections
        "<table[^>]*class=\"[^\"]*social[^\"]*\"[^>]*>.*?</table>",
        "<div[^>]*class=\"[^\"]*social[^\"]*\"[^>]*>.*?</div>",

        // Unsubscribe sections
        "<div[^>]*class=\"[^\"]*unsubscribe[^\"]*\"[^>]*>.*?</div>",
        "<p[^>]*class=\"[^\"]*unsubscribe[^\"]*\"[^>]*>.*?</p>",

        // Signature blocks
        "<div class=\"gmail_signature\">.*?</div>",
        "<div class=\"gmail_signature_prefix\">.*?</div>",
        "<div id=\"Signature\">.*?</div>",
        "<div class=\"signature\">.*?</div>",
        "<div[^>]*class=\"[^\"]*moz-signature[^\"]*\"[^>]*>.*?</div>",
        "<div[^>]*class=\"[^\"]*ms-outlook-signature[^\"]*\"[^>]*>.*?</div>",
        "<div[^>]*(?:id|class)=\"[^\"]*ms-outlook-mobile-signature[^\"]*\"[^>]*>.*?</div>",

        // Generic signature wrappers
        "<div[^>]*class=\"[^\"]*sig[^\"]*\"[^>]*>.*?</div>",
        "<table[^>]*class=\"[^\"]*signature[^\"]*\"[^>]*>.*?</table>",

        // Professional signature tables (contain phone/contact info patterns)
        "<table[^>]*>(?:[^<]*<(?:tr|td|th|tbody|thead)[^>]*>)*[^<]*(?:phone|tel:|mobile|cell|office|fax|direct)[^<]*(?:</(?:tr|td|th|tbody|thead)>[^<]*)*</table>",

        // Real estate and professional signature patterns
        "<table[^>]*>(?:[^<]*<[^>]*>)*[^<]*(?:realtor|licensed|broker|brokerage|DRE#|Lic#|NMLS|sales associate)[^<]*(?:<[^>]*>[^<]*)*</table>",
        "<div[^>]*>(?:[^<]*<[^>]*>)*[^<]*(?:realtor|licensed|broker|brokerage|DRE#|Lic#|NMLS|sales associate)[^<]*(?:<[^>]*>[^<]*)*</div>",

        // Company branding blocks (tables with company names followed by contact info)
        "<table[^>]*>(?:[^<]*<[^>]*>)*[^<]*(?:corcoran|compass|sotheby|keller williams|coldwell banker|remax|re/max|century 21|berkshire hathaway)[^<]*(?:<[^>]*>[^<]*)*</table>",
    ]

    /// Structural HTML patterns that definitively mark quote boundaries.
    /// These are checked FIRST and if found, text-based patterns are skipped.
    private static let structuralTruncationPatternStrings = [
        // Outlook reference container (ID-based, handles prefixed IDs like "x_mail-editor-reference-message-container")
        "<div[^>]*id=\"[^\"]*mail-editor-reference-message-container[^\"]*\"[^>]*>",
        // Outlook desktop often marks quoted sections with a gray top border block that
        // contains From/Sent/To/Subject headers followed by the quoted thread.
        // Truncate at this boundary instead of removing only the header block.
        "<div[^>]*style=\"[^\"]*border-top\\s*:\\s*solid\\s*#E1E1E1[^\"]*\"[^>]*>(?=[\\s\\S]{0,3000}\\bFrom:)(?=[\\s\\S]{0,3000}\\b(?:Sent:|Date:))(?=[\\s\\S]{0,3000}\\bTo:)(?=[\\s\\S]{0,3000}\\bSubject:)",
    ]

    /// Text-based patterns that indicate quoted content.
    /// These are ONLY checked if no structural boundary was found, since they can
    /// produce false positives when appearing in main email content.
    private static let textBasedTruncationPatternStrings = [
        // Require "On" at start of string, after line break, paragraph, or closing tag
        // to avoid mid-sentence matches (e.g., "reload on the Chablis" should not match)
        "(?:^|<br>|<p>|>)\\s*On .+? wrote:",
        // iOS/Apple Mail format: "On Jan 30, 2026 at 7:32 PM, Name" (wrote: may be on next line)
        "(?:^|<br>|<p>|>)\\s*On [A-Z][a-z]+ \\d{1,2}, \\d{4} at \\d{1,2}:\\d{2}\\s*[AP]M,",
        "From:</strong>.*?Subject:</strong>",
        "-----Original Message-----",
    ]

    /// Signature wrapper patterns that need block-aware removal because nested divs
    /// can defeat simple regex-based stripping.
    private static let signatureWrapperPatternStrings = [
        "<div[^>]*class=\"[^\"]*gmail_signature_prefix[^\"]*\"[^>]*>",
        "<div[^>]*class=\"[^\"]*gmail_signature[^\"]*\"[^>]*>",
        "<div[^>]*data-smartmail=\"gmail_signature\"[^>]*>",
        "<div[^>]*(?:id|class)=\"[^\"]*ms-outlook-mobile-signature[^\"]*\"[^>]*>"
    ]

    /// Signature/footer text patterns. These are applied only in
    /// `.quotedAndSignatures` mode.
    private static let signatureTextTruncationPatternStrings = [
        // Signature delimiters (plain text within HTML)
        "<br>\\s*--\\s*<br>",
        "<br>\\s*--\\s*</div>",
        "<p>\\s*--\\s*</p>",
        "<div>\\s*--\\s*</div>",

        // Mobile signatures
        "Sent from my iPhone",
        "Sent from my iPad",
        "Sent from my Android",
        "Sent from Outlook",
        "Get Outlook for",
        "Sent from Mail for Windows",
        "Sent from Samsung",
        "Sent from my Galaxy",
        "Sent from my Pixel",
        "Sent from Spark",
        "Sent from ProtonMail",
        "Sent from BlueMail",
        "Sent from Gmail",
        "Sent from Yahoo Mail",

        // Confidentiality notices
        "Notice To Recipient:",
        "This email is confidential",
        "This e-mail is meant for only the intended recipient",
        "This message is confidential",
        "The information contained in this",
        "If you are not the intended recipient",
        "If you received this e-mail in error",
        "For additional policies governing this e-mail",

        // Professional contact patterns (often start signature blocks)
        "<br[^>]*>\\s*M:\\s*\\d",    // Mobile: followed by number
        "<br[^>]*>\\s*C:\\s*\\d",    // Cell: followed by number
        "<br[^>]*>\\s*O:\\s*\\d",    // Office: followed by number
        "<br[^>]*>\\s*F:\\s*\\d",    // Fax: followed by number
        "<br[^>]*>\\s*Direct:\\s*\\d",
        "<br[^>]*>\\s*Mobile:\\s*\\d",
        "<br[^>]*>\\s*Cell:\\s*\\d",
        "<br[^>]*>\\s*Office:\\s*\\d",
        "<br[^>]*>\\s*Phone:\\s*\\d",
        "<br[^>]*>\\s*Tel:\\s*\\d",

        // Wire fraud warnings (common in real estate emails)
        "\\*Wire Fraud",
        "Wire Fraud is Real",
        "Before wiring any money",
    ]

    /// Pre-compiled regex patterns for quote block removal (compiled once at class load)
    private static let compiledQuotedBlockPatterns: [NSRegularExpression] = {
        quotedBlockPatternStrings.compactMap {
            try? NSRegularExpression(pattern: $0, options: [.caseInsensitive, .dotMatchesLineSeparators])
        }
    }()

    /// Pre-compiled regex patterns for signature block removal.
    private static let compiledSignatureBlockPatterns: [NSRegularExpression] = {
        signatureBlockPatternStrings.compactMap {
            try? NSRegularExpression(pattern: $0, options: [.caseInsensitive, .dotMatchesLineSeparators])
        }
    }()

    /// Pre-compiled structural truncation patterns (checked first)
    private static let compiledStructuralTruncationPatterns: [NSRegularExpression] = {
        structuralTruncationPatternStrings.compactMap {
            try? NSRegularExpression(pattern: $0, options: [.caseInsensitive, .dotMatchesLineSeparators])
        }
    }()

    /// Pre-compiled signature wrapper patterns.
    private static let compiledSignatureWrapperPatterns: [NSRegularExpression] = {
        signatureWrapperPatternStrings.compactMap {
            try? NSRegularExpression(pattern: $0, options: [.caseInsensitive, .dotMatchesLineSeparators])
        }
    }()

    /// Pre-compiled text-based truncation patterns (checked only if no structural boundary found)
    private static let compiledTextBasedTruncationPatterns: [NSRegularExpression] = {
        textBasedTruncationPatternStrings.compactMap {
            try? NSRegularExpression(pattern: $0, options: [.caseInsensitive, .dotMatchesLineSeparators])
        }
    }()

    /// Pre-compiled signature/footer truncation patterns.
    private static let compiledSignatureTextTruncationPatterns: [NSRegularExpression] = {
        signatureTextTruncationPatternStrings.compactMap {
            try? NSRegularExpression(pattern: $0, options: [.caseInsensitive, .dotMatchesLineSeparators])
        }
    }()

    // MARK: - Public API

    /// Removes quoted text from HTML email content
    /// - Parameter html: The HTML content to clean
    /// - Parameter mode: Whether to remove only quoted history or quoted history + signatures
    /// - Returns: HTML with quote blocks removed, or nil if input was nil
    static func removeQuotes(from html: String?, mode: RemovalMode = .quotedAndSignatures) -> String? {
        guard let html = html else { return nil }

        // When the DOM pipeline is enabled at runtime, delegate to the DOM-based
        // implementation. The legacy regex pipeline below remains the default to
        // preserve behavior until parity is verified by the existing test suites.
        if EmailDOMFeatureFlag.isQuoteRemovalEnabled() {
            return EmailDOMQuoteRemover.removeQuotes(from: html, mode: mode)
        }

        var cleanedHTML = html

        // Remove quote block patterns using pre-compiled regex.
        cleanedHTML = removePatterns(compiledQuotedBlockPatterns, from: cleanedHTML)

        // Two-pass truncation approach:
        // 1. First check structural patterns (definitive quote boundaries like Outlook containers)
        // 2. Only apply text-based patterns if no structural boundary was found
        //    (text patterns like "On ... wrote:" can produce false positives in main content)
        let structuralResult = truncateAtEarliestMatch(compiledStructuralTruncationPatterns, in: cleanedHTML)
        if structuralResult.didTruncate {
            // Structural boundary found - use that result, skip text-based patterns
            cleanedHTML = structuralResult.text
        } else {
            // No structural boundary - fall back to text-based patterns
            cleanedHTML = truncateAtPatterns(compiledTextBasedTruncationPatterns, in: cleanedHTML)
        }

        if mode == .quotedAndSignatures {
            cleanedHTML = removeSignatureWrapperBlocks(from: cleanedHTML)
            cleanedHTML = removePatterns(compiledSignatureBlockPatterns, from: cleanedHTML)
            cleanedHTML = truncateAtPatterns(compiledSignatureTextTruncationPatterns, in: cleanedHTML)
        }

        return cleanedHTML
    }

    // MARK: - Private Helpers

    /// Removes all occurrences of patterns from the text using pre-compiled regex
    private static func removePatterns(_ patterns: [NSRegularExpression], from text: String) -> String {
        var result = text

        for regex in patterns {
            let range = NSRange(location: 0, length: result.utf16.count)
            result = regex.stringByReplacingMatches(
                in: result,
                options: [],
                range: range,
                withTemplate: ""
            )
        }

        return result
    }

    /// Truncates text at the first occurrence of any pattern using pre-compiled regex
    private static func truncateAtPatterns(_ patterns: [NSRegularExpression], in text: String) -> String {
        var result = text

        for regex in patterns {
            let range = NSRange(location: 0, length: result.utf16.count)
            if let match = regex.firstMatch(in: result, options: [], range: range),
               let matchRange = Range(match.range, in: result) {
                result = String(result[..<matchRange.lowerBound])
            }
        }

        return result
    }

    /// Truncates text at the earliest match among the given patterns
    /// Returns the truncated text and whether any truncation occurred
    private static func truncateAtEarliestMatch(
        _ patterns: [NSRegularExpression],
        in text: String
    ) -> (text: String, didTruncate: Bool) {
        var earliestPosition: String.Index?

        for regex in patterns {
            let range = NSRange(location: 0, length: text.utf16.count)
            if let match = regex.firstMatch(in: text, options: [], range: range),
               let matchRange = Range(match.range, in: text) {
                if earliestPosition == nil || matchRange.lowerBound < earliestPosition! {
                    earliestPosition = matchRange.lowerBound
                }
            }
        }

        if let position = earliestPosition {
            return (String(text[..<position]), true)
        }
        return (text, false)
    }

    /// Removes nested signature wrapper divs without truncating later siblings.
    /// If the wrapper starts with a lightweight sign-off like "Best,\nJanet",
    /// preserve that prefix while stripping the heavier signature payload.
    private static func removeSignatureWrapperBlocks(from html: String) -> String {
        var result = html
        var searchRange = result.startIndex..<result.endIndex

        while let match = earliestMatch(of: compiledSignatureWrapperPatterns, in: result, range: searchRange),
              let matchRange = Range(match.range, in: result) {
            let wrapperStart = matchRange.lowerBound
            guard let wrapperEnd = findMatchingClosingDiv(in: result, from: wrapperStart) else {
                searchRange = matchRange.upperBound..<result.endIndex
                continue
            }
            let startOffset = result.distance(from: result.startIndex, to: wrapperStart)
            let blockHTML = String(result[wrapperStart..<wrapperEnd])
            let replacement = preservedSignOffHTML(fromSignatureBlock: blockHTML)

            result.replaceSubrange(wrapperStart..<wrapperEnd, with: replacement)

            let nextOffset = min(startOffset + replacement.count, result.count)
            let nextIndex = result.index(result.startIndex, offsetBy: nextOffset)
            searchRange = nextIndex..<result.endIndex
        }

        return result
    }

    private static func earliestMatch(
        of patterns: [NSRegularExpression],
        in text: String,
        range: Range<String.Index>
    ) -> NSTextCheckingResult? {
        let searchRange = NSRange(range, in: text)
        var earliest: NSTextCheckingResult?

        for regex in patterns {
            guard let match = regex.firstMatch(in: text, options: [], range: searchRange) else { continue }
            if earliest == nil || match.range.location < earliest!.range.location {
                earliest = match
            }
        }

        return earliest
    }

    private static func preservedSignOffHTML(fromSignatureBlock blockHTML: String) -> String {
        let extracted = HTMLEntityDecoder.decode(TextProcessing.extractPlainText(from: blockHTML))
        var lines = extracted
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        if lines.first == "--" {
            lines.removeFirst()
        }

        guard !lines.isEmpty else { return "" }

        if isLikelyCombinedSignOffAndNameLine(lines[0]) {
            return "<div>\(escapedHTML(lines[0]))</div>"
        }

        guard isLikelySignOffLine(lines[0]) else { return "" }

        var preserved = [lines[0]]
        if lines.count > 1, looksLikeNameLine(lines[1]) {
            preserved.append(lines[1])
        }

        return preserved
            .map { "<div>\(escapedHTML($0))</div>" }
            .joined()
    }

    private static func isLikelySignOffLine(_ line: String) -> Bool {
        let normalized = line
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: .punctuationCharacters)

        let signOffs = [
            "all the best",
            "best",
            "best regards",
            "best wishes",
            "cheers",
            "kind regards",
            "many thanks",
            "regards",
            "sincerely",
            "thank you",
            "thanks",
            "warm regards",
            "warmly",
            "yours truly"
        ]

        return signOffs.contains(normalized)
    }

    private static func isLikelyCombinedSignOffAndNameLine(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count <= 60 else { return false }

        let lowercased = trimmed.lowercased()
        let signOffs = [
            "all the best",
            "best regards",
            "best wishes",
            "best",
            "cheers",
            "kind regards",
            "many thanks",
            "regards",
            "sincerely",
            "thank you",
            "thanks",
            "warm regards",
            "warmly",
            "yours truly"
        ]

        for signOff in signOffs {
            for separator in [",", " "] {
                let prefix = signOff + separator
                guard lowercased.hasPrefix(prefix) else { continue }
                let remainder = String(trimmed.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
                return looksLikeNameLine(String(remainder))
            }
        }

        return false
    }

    private static func looksLikeNameLine(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 40 else { return false }
        guard trimmed.rangeOfCharacter(from: .letters) != nil else { return false }
        guard trimmed.rangeOfCharacter(from: .decimalDigits) == nil else { return false }

        let lowercased = trimmed.lowercased()
        let disallowedFragments = ["@", "http", "www.", "|", "tel:", "fax", "mobile", "office", "cell", "phone"]
        guard !disallowedFragments.contains(where: { lowercased.contains($0) }) else { return false }

        let words = trimmed.split(whereSeparator: \.isWhitespace)
        guard (1...4).contains(words.count) else { return false }

        return true
    }

    private static func escapedHTML(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    private static func findMatchingClosingDiv(in html: String, from start: String.Index) -> String.Index? {
        var depth = 0
        var searchIndex = start

        while searchIndex < html.endIndex {
            let nextOpen = html.range(of: "<div", options: .caseInsensitive, range: searchIndex..<html.endIndex)
            let nextClose = html.range(of: "</div", options: .caseInsensitive, range: searchIndex..<html.endIndex)

            switch (nextOpen, nextClose) {
            case let (open?, close?):
                if open.lowerBound < close.lowerBound {
                    depth += 1
                    searchIndex = open.upperBound
                } else {
                    depth -= 1
                    guard let closeTagEnd = html[close.lowerBound...].firstIndex(of: ">") else { return nil }
                    let afterClose = html.index(after: closeTagEnd)
                    searchIndex = afterClose
                    if depth == 0 {
                        return afterClose
                    }
                }
            case let (open?, nil):
                depth += 1
                searchIndex = open.upperBound
            case let (nil, close?):
                depth -= 1
                guard let closeTagEnd = html[close.lowerBound...].firstIndex(of: ">") else { return nil }
                let afterClose = html.index(after: closeTagEnd)
                searchIndex = afterClose
                if depth == 0 {
                    return afterClose
                }
            case (nil, nil):
                return nil
            }
        }

        return nil
    }
}
