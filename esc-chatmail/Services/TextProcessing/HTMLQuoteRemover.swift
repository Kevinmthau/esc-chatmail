import Foundation

/// Removes quoted text blocks from HTML email content
/// Handles Gmail, Outlook, Apple Mail, and generic quote patterns
enum HTMLQuoteRemover {

    // MARK: - Quote Patterns

    /// HTML quote block patterns to remove entirely (string form for reference)
    private static let quoteBlockPatternStrings = [
        // Gmail quote blocks (flexible class matching for multiple classes like "gmail_quote gmail_quote_container")
        "<div[^>]*class=\"[^\"]*gmail_quote[^\"]*\"[^>]*>.*?</div>",
        "<div[^>]*class=\"[^\"]*gmail_attr[^\"]*\"[^>]*>.*?</div>",
        "<blockquote[^>]*>.*?</blockquote>",

        // Outlook/Office 365
        "<div class=\"OutlookMessageHeader\">.*?</div>",
        "<div style=\"border:none;border-top:solid #E1E1E1[^>]*>.*?</div>",

        // Apple Mail
        "<br><div><br><blockquote type=\"cite\">.*?</blockquote></div>",
        "<div class=\"AppleMailSignature\">.*?</div>",

        // Generic quoted sections
        "<div style=\"[^\"]*border-left:[^\"]*\">.*?</div>",
        "<!-- originalMessage -->.*?<!-- /originalMessage -->",
        "<div class=\"moz-cite-prefix\">.*?</div>",

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

    /// Patterns that indicate the start of quoted content (truncate from here) - string form
    private static let quoteTruncationPatternStrings = [
        "On .+? wrote:",
        // iOS/Apple Mail format: "On Jan 30, 2026 at 7:32 PM, Name" (wrote: may be on next line)
        "On [A-Z][a-z]+ \\d{1,2}, \\d{4} at \\d{1,2}:\\d{2}\\s*[AP]M,",
        "From:</strong>.*?Subject:</strong>",
        "-----Original Message-----",
        // Outlook reference container (ID-based, handles prefixed IDs like "x_mail-editor-reference-message-container")
        "<div[^>]*id=\"[^\"]*mail-editor-reference-message-container[^\"]*\"[^>]*>",
        // Outlook blue border separator (#b5c4df)
        "<div[^>]*style=\"[^\"]*border-top:[^\"]*solid[^\"]*#[Bb]5[Cc]4[Dd][Ff][^\"]*\"[^>]*>",
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
        "This email is confidential",
        "This message is confidential",
        "The information contained in this",
        "If you are not the intended recipient",

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
    private static let compiledQuoteBlockPatterns: [NSRegularExpression] = {
        quoteBlockPatternStrings.compactMap {
            try? NSRegularExpression(pattern: $0, options: [.caseInsensitive, .dotMatchesLineSeparators])
        }
    }()

    /// Pre-compiled regex patterns for truncation (compiled once at class load)
    private static let compiledTruncationPatterns: [NSRegularExpression] = {
        quoteTruncationPatternStrings.compactMap {
            try? NSRegularExpression(pattern: $0, options: [.caseInsensitive, .dotMatchesLineSeparators])
        }
    }()

    // MARK: - Public API

    /// Removes quoted text from HTML email content
    /// - Parameter html: The HTML content to clean
    /// - Returns: HTML with quote blocks removed, or nil if input was nil
    static func removeQuotes(from html: String?) -> String? {
        guard let html = html else { return nil }

        var cleanedHTML = html

        // Remove quote block patterns using pre-compiled regex
        cleanedHTML = removePatterns(compiledQuoteBlockPatterns, from: cleanedHTML)

        // Truncate at "On ... wrote:" and similar patterns using pre-compiled regex
        cleanedHTML = truncateAtPatterns(compiledTruncationPatterns, in: cleanedHTML)

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
}
