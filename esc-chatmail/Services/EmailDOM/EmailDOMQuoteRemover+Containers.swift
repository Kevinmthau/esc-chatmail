import Foundation
import SwiftSoup

// MARK: - Containers (provider-specific)
//
// Removes entire quoted-history subtrees by CSS selector (Gmail, Apple Mail,
// Mozilla, Outlook, generic blockquotes), plus border-left styled quote divs
// and Outlook comment-delimited regions.
extension EmailDOMQuoteRemover {

    /// CSS selectors for elements whose entire subtree should be removed
    /// because they are the quoted history.
    private static let quotedContainerSelectors: [String] = [
        // Gmail
        "div.gmail_quote",
        "div.gmail_attr",
        // Apple Mail
        "blockquote[type=cite]",
        "div.AppleMailSignature",
        // Mozilla / Thunderbird
        "div.moz-cite-prefix",
        // Outlook desktop
        "div.OutlookMessageHeader",
        // Generic
        "blockquote",
        // HTML comment markers handled separately because SwiftSoup represents
        // them as Comment nodes, not Elements.
    ]

    static func removeQuotedContainers(in document: Document) throws {
        // border-left styled divs are commonly used as quote blocks; match by
        // attribute value substring rather than encoded inline style strings.
        let borderLeftDivs = try document.select("div[style*=border-left]")
        for element in borderLeftDivs.array() {
            try element.remove()
        }

        for selector in quotedContainerSelectors {
            let elements = try document.select(selector)
            for element in elements.array() {
                try element.remove()
            }
        }

        // Remove `<!-- originalMessage --> … <!-- /originalMessage -->` pairs.
        removeCommentDelimitedRegions(in: document, openHint: "originalmessage", closeHint: "/originalmessage")
    }
}
