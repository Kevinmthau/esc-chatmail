import Foundation
import SwiftUI

/// Facade for email text processing operations
/// Delegates to specialized components in /Services/TextProcessing/
class EmailTextProcessor {

    // MARK: - HTML Processing

    /// Removes quoted text from HTML email content
    /// - Parameter html: The HTML content to clean
    /// - Returns: HTML with quote blocks removed, or nil if input was nil
    static func removeQuotedFromHTML(_ html: String?) -> String? {
        HTMLQuoteRemover.removeQuotes(from: html)
    }

    /// Extracts plain text from HTML, removing tags but preserving structure
    /// - Parameter html: The HTML content to extract text from
    /// - Returns: Plain text extracted from the HTML
    static func extractPlainFromHTML(_ html: String) -> String {
        // Convert HTML to AttributedString to extract plain text
        guard let data = html.data(using: .utf8) else { return html }

        do {
            let attributed = try NSAttributedString(
                data: data,
                options: [
                    .documentType: NSAttributedString.DocumentType.html,
                    .characterEncoding: String.Encoding.utf8.rawValue
                ],
                documentAttributes: nil
            )
            return attributed.string
        } catch {
            // Fallback: basic HTML tag removal
            var text = html
                .replacingOccurrences(of: "<br>", with: "\n")
                .replacingOccurrences(of: "<br/>", with: "\n")
                .replacingOccurrences(of: "<br />", with: "\n")
                .replacingOccurrences(of: "</p>", with: "\n")
                .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)

            // Decode HTML entities
            text = HTMLEntityDecoder.decode(text)

            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    // MARK: - Plain Text Processing

    /// Removes quoted text from plain text email content
    /// - Parameter text: The plain text content to clean
    /// - Returns: Text with quotes and signatures removed, or nil if input was nil
    static func removeQuotedFromPlainText(_ text: String?) -> String? {
        PlainTextQuoteRemover.removeQuotes(from: text)
    }

    // MARK: - Snippet Creation

    /// Creates a clean snippet from email content
    /// - Parameters:
    ///   - text: The text to create a snippet from
    ///   - maxLength: Maximum length of the snippet (default 5000 to show all new content)
    ///   - firstSentenceOnly: If true, returns only the first sentence
    /// - Returns: A cleaned and optionally truncated snippet
    static func createCleanSnippet(
        from text: String?,
        maxLength: Int = 5000,
        firstSentenceOnly: Bool = false
    ) -> String {
        TextSnippetCreator.createSnippet(
            from: text,
            maxLength: maxLength,
            firstSentenceOnly: firstSentenceOnly
        )
    }

    // MARK: - Attributed String

    /// Creates an attributed string from HTML for rich display
    /// - Parameter html: The HTML content to convert
    /// - Returns: An AttributedString, or nil if conversion fails
    static func createAttributedString(fromHTML html: String?) -> AttributedString? {
        guard let html = html else { return nil }

        // Clean the HTML first
        guard let cleanedHTML = removeQuotedFromHTML(html) else { return nil }

        // Convert to AttributedString
        guard let data = cleanedHTML.data(using: .utf8) else { return nil }

        do {
            let nsAttributed = try NSAttributedString(
                data: data,
                options: [
                    .documentType: NSAttributedString.DocumentType.html,
                    .characterEncoding: String.Encoding.utf8.rawValue
                ],
                documentAttributes: nil
            )
            return AttributedString(nsAttributed)
        } catch {
            Log.debug("Failed to create attributed string from HTML: \(error)", category: .message)
            return nil
        }
    }
}
