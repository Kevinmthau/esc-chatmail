import Foundation

/// Removes quoted text blocks from HTML email content
/// Handles Gmail, Outlook, Apple Mail, and generic quote patterns
enum HTMLQuoteRemover {

    // MARK: - Quote Patterns

    /// HTML quote block patterns to remove entirely
    private static let quoteBlockPatterns = [
        // Gmail quote blocks
        "<div class=\"gmail_quote\">.*?</div>",
        "<blockquote[^>]*>.*?</blockquote>",

        // Outlook/Office 365
        "<div class=\"OutlookMessageHeader\">.*?</div>",
        "<div style=\"border:none;border-top:solid #E1E1E1[^>]*>.*?</div>",

        // Apple Mail
        "<br><div><br><blockquote type=\"cite\">.*?</blockquote></div>",

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
    ]

    /// Patterns that indicate the start of quoted content (truncate from here)
    private static let quoteTruncationPatterns = [
        "On .+? wrote:",
        "From:</strong>.*?Subject:</strong>",
        "-----Original Message-----",
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
    ]

    // MARK: - Public API

    /// Removes quoted text from HTML email content
    /// - Parameter html: The HTML content to clean
    /// - Returns: HTML with quote blocks removed, or nil if input was nil
    static func removeQuotes(from html: String?) -> String? {
        guard let html = html else { return nil }

        var cleanedHTML = html

        // Remove quote block patterns
        cleanedHTML = removePatterns(quoteBlockPatterns, from: cleanedHTML)

        // Truncate at "On ... wrote:" and similar patterns
        cleanedHTML = truncateAtPatterns(quoteTruncationPatterns, in: cleanedHTML)

        return cleanedHTML
    }

    // MARK: - Private Helpers

    /// Removes all occurrences of patterns from the text
    private static func removePatterns(_ patterns: [String], from text: String) -> String {
        var result = text

        for pattern in patterns {
            guard let regex = try? NSRegularExpression(
                pattern: pattern,
                options: [.caseInsensitive, .dotMatchesLineSeparators]
            ) else { continue }

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

    /// Truncates text at the first occurrence of any pattern
    private static func truncateAtPatterns(_ patterns: [String], in text: String) -> String {
        var result = text

        for pattern in patterns {
            guard let regex = try? NSRegularExpression(
                pattern: pattern,
                options: [.caseInsensitive, .dotMatchesLineSeparators]
            ) else { continue }

            let range = NSRange(location: 0, length: result.utf16.count)
            if let match = regex.firstMatch(in: result, options: [], range: range),
               let matchRange = Range(match.range, in: result) {
                result = String(result[..<matchRange.lowerBound])
            }
        }

        return result
    }
}
