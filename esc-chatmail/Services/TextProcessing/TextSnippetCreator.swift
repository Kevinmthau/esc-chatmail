import Foundation

/// Creates clean snippets from email content for preview display
enum TextSnippetCreator {

    // MARK: - Public API

    /// Creates a clean snippet from email content
    /// - Parameters:
    ///   - text: The text to create a snippet from
    ///   - maxLength: Maximum length of the snippet (default 5000 to show all new content)
    ///   - firstSentenceOnly: If true, returns only the first sentence
    /// - Returns: A cleaned and optionally truncated snippet
    static func createSnippet(
        from text: String?,
        maxLength: Int = 5000,
        firstSentenceOnly: Bool = false
    ) -> String {
        guard let text = text, !text.isEmpty else { return "" }

        // Clean the text by removing quotes
        let cleanedText = PlainTextQuoteRemover.removeQuotes(from: text) ?? text

        // Remove excessive whitespace and newlines
        let condensed = cleanedText
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")

        // If only first sentence is requested, extract it
        if firstSentenceOnly {
            return extractFirstSentence(from: condensed)
        }

        // Truncate if needed
        if condensed.count > maxLength {
            let endIndex = condensed.index(condensed.startIndex, offsetBy: maxLength)
            return String(condensed[..<endIndex]) + "..."
        }

        return condensed
    }

    // MARK: - Private Helpers

    /// Extracts the first sentence from text
    /// - Parameter text: The text to extract from
    /// - Returns: The first sentence, or truncated text if no sentence ending found
    private static func extractFirstSentence(from text: String) -> String {
        // Look for sentence-ending punctuation followed by space or end of string
        let sentenceEndPattern = "[.!?](?:\\s|$)"

        if let regex = try? NSRegularExpression(pattern: sentenceEndPattern, options: []),
           let match = regex.firstMatch(in: text, options: [], range: NSRange(location: 0, length: text.utf16.count)),
           let range = Range(match.range, in: text) {
            let endIndex = range.upperBound
            return String(text[..<endIndex]).trimmingCharacters(in: .whitespaces)
        }

        // If no sentence ending found, return the whole text (up to a reasonable limit)
        let limit = min(text.count, 200)
        let endIndex = text.index(text.startIndex, offsetBy: limit)
        let snippet = String(text[..<endIndex])
        return limit < text.count ? snippet + "..." : snippet
    }
}
