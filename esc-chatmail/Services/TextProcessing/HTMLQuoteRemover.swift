import Foundation

/// Removes quoted text blocks from HTML email content
/// Handles Gmail, Outlook, Apple Mail, and generic quote patterns
enum HTMLQuoteRemover {

    enum RemovalMode {
        case quotedOnly
        case quotedAndSignatures
    }

    // MARK: - Public API

    /// Removes quoted text from HTML email content
    /// - Parameter html: The HTML content to clean
    /// - Parameter mode: Whether to remove only quoted history or quoted history + signatures
    /// - Returns: HTML with quote blocks removed, or nil if input was nil
    static func removeQuotes(from html: String?, mode: RemovalMode = .quotedAndSignatures) -> String? {
        EmailDOMQuoteRemover.removeQuotes(from: html, mode: mode)
    }
}
