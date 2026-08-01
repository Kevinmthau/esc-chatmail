import Foundation

/// Removes quoted text blocks from HTML email content
/// Handles Gmail, Outlook, Apple Mail, and generic quote patterns
enum HTMLQuoteRemover {

    enum RemovalMode {
        case quotedOnly
        case quotedAndSignatures
        /// Selector-based container removal only (quote containers, signature
        /// wrappers, footers) — no structural or text-marker truncation. Used
        /// as the last cleanup fallback for quote-first replies whose actual
        /// content sits AFTER the quoted block: marker truncation removes
        /// everything from the attribution line onward, so this mode keeps
        /// the content and drops just the quoted subtrees.
        case quotedContainersOnly
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
