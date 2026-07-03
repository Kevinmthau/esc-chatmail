import Foundation
import SwiftSoup

// MARK: - Footer containers (newsletter unsubscribe, social icons)
//
// Removes whole footer/social/unsubscribe blocks by class/id selector. Only
// runs in `.quotedAndSignatures` mode.
extension EmailDOMQuoteRemover {

    // Substring matching is deliberate for these: token-anchoring would
    // regress camelCase/underscore templates (footerContainer, footer_wrap,
    // social_links), and none of these substrings have realistic false
    // positives. `sig` is the exception — see below.
    private static let footerSelectors: [String] = [
        "div[class*=footer]",
        "table[class*=footer]",
        "div[id*=footer]",
        "table[class*=social]",
        "div[class*=social]",
        "div[class*=unsubscribe]",
        "p[class*=unsubscribe]",
        "table[class*=signature]"
    ]

    /// Signature wrappers are matched by whole class-name token, not
    /// substring: `div[class*=sig]` removed design/signup/insights/assignment
    /// layouts (de[sig]n, [sig]nup, in[sig]hts, as[sig]nment) — real content
    /// loss. Tokens split on whitespace, hyphen, and underscore, lowercased
    /// (matching jsoup's case-insensitive attribute comparison).
    private static let signatureClassTokens: Set<Substring> = ["sig", "signature"]

    /// A matched container holding at least this share of the document's
    /// visible text is the message, not a footer — remove it and the bubble
    /// is wiped (the downstream empty-content degradation chain exists in
    /// three copies precisely because of that). Skipping removal here fixes
    /// the wipeout at the source. Tunable; conservative majority.
    static let majorityTextGuardRatio = 0.6

    static func removeFooterContainers(in document: Document) throws {
        // Baseline measured once against the original document so earlier
        // removals in this pass don't inflate later elements' share.
        let documentTextLength = try visibleTextLength(of: document)

        for selector in footerSelectors {
            let elements = try document.select(selector)
            for element in elements.array() {
                try removeUnlessMajorityText(element, documentTextLength: documentTextLength)
            }
        }
        try removeSignatureTokenDivs(in: document, documentTextLength: documentTextLength)
    }

    private static func removeSignatureTokenDivs(in document: Document, documentTextLength: Int) throws {
        for element in try document.select("div[class]").array() {
            let classAttribute = try element.attr("class").lowercased()
            let tokens = classAttribute.split { character in
                character == "-" || character == "_" || character.isWhitespace
            }
            if tokens.contains(where: signatureClassTokens.contains) {
                try removeUnlessMajorityText(element, documentTextLength: documentTextLength)
            }
        }
    }

    private static func removeUnlessMajorityText(_ element: Element, documentTextLength: Int) throws {
        // Text-free documents (hero-image newsletters) keep unguarded removal:
        // there is no text majority to protect.
        guard documentTextLength > 0 else {
            try element.remove()
            return
        }

        let elementTextLength = try visibleTextLength(of: element)
        if Double(elementTextLength) >= Double(documentTextLength) * majorityTextGuardRatio {
            return
        }
        try element.remove()
    }

    private static func visibleTextLength(of node: Element) throws -> Int {
        try node.text().trimmingCharacters(in: .whitespacesAndNewlines).count
    }
}
