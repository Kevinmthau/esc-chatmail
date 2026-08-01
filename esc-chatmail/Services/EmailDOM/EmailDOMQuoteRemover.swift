import Foundation
import SwiftSoup

/// DOM-based replacement for `HTMLQuoteRemover`.
///
/// Walks the document and removes:
/// 1. Provider-specific quote containers (gmail_quote, blockquote[type=cite],
///    AppleMailSignature, OutlookMessageHeader, moz-cite-prefix, etc.) by
///    CSS selector — no nested-div counting needed because SwiftSoup tracks
///    the tree structure.
/// 2. Structural quote boundaries (Outlook reference container,
///    border-top header tables) by truncating subsequent siblings.
/// 3. Text-based quote markers ("On … wrote:", "-----Original Message-----")
///    by finding the text node and removing the node and all subsequent
///    siblings at every ancestor level.
/// 4. (Optional, mode = .quotedAndSignatures) Signature wrappers
///    (gmail_signature, ms-outlook-signature) and footer/unsubscribe
///    sections.
///
/// `HTMLQuoteRemover.removeQuotes(from:mode:)` delegates here for the public
/// quote-removal path.
enum EmailDOMQuoteRemover {

    typealias RemovalMode = HTMLQuoteRemover.RemovalMode

    /// Mirror of `HTMLQuoteRemover.removeQuotes(from:mode:)` using the DOM.
    /// Returns `nil` for `nil` input, mirroring the legacy contract.
    /// On parser failure or any internal error, falls back to the input
    /// unchanged rather than returning nil — callers depend on a String result
    /// being a meaningful representation.
    static func removeQuotes(from html: String?, mode: RemovalMode = .quotedAndSignatures) -> String? {
        guard let html else { return nil }

        // Match legacy contract: if the input was a fragment (no document
        // structure), emit a fragment by returning body's inner HTML. Otherwise
        // emit the full document. Compose-time reply quoting depends on this —
        // wrapping a fragment with `<html><body>` would corrupt outgoing MIME
        // parts.
        let inputIsFragment = !hasDocumentWrapper(html)
        guard let document = try? EmailDOMFragmentParser.parse(
            html,
            inputIsFragment: inputIsFragment
        ) else {
            return html
        }
        document.outputSettings().prettyPrint(pretty: false)

        do {
            try removeQuotedContainers(in: document)
            if mode != .quotedContainersOnly {
                let didTruncateAtStructuralBoundary = try truncateAtStructuralBoundaries(in: document)
                if !didTruncateAtStructuralBoundary {
                    try truncateAtTextMarkers(in: document)
                }
            }
            if mode == .quotedAndSignatures || mode == .quotedContainersOnly {
                try removeSignatureWrappers(in: document)
                try removeFooterContainers(in: document)
            }
            if mode == .quotedAndSignatures {
                try truncateAtSignatureMarkers(in: document)
                try truncateTrailingContactSignature(in: document)
            }
            if inputIsFragment, let body = document.body() {
                return try body.html()
            }
            return try document.outerHtml()
        } catch {
            // SwiftSoup throws on misuse, not on malformed HTML. If we land
            // here something is broken in the selector strings; degrade
            // gracefully.
            return html
        }
    }

}
