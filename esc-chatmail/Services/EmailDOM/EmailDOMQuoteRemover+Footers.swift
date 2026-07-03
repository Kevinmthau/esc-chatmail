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

    static func removeFooterContainers(in document: Document) throws {
        for selector in footerSelectors {
            let elements = try document.select(selector)
            for element in elements.array() {
                try element.remove()
            }
        }
        try removeSignatureTokenDivs(in: document)
    }

    private static func removeSignatureTokenDivs(in document: Document) throws {
        for element in try document.select("div[class]").array() {
            let classAttribute = try element.attr("class").lowercased()
            let tokens = classAttribute.split { character in
                character == "-" || character == "_" || character.isWhitespace
            }
            if tokens.contains(where: signatureClassTokens.contains) {
                try element.remove()
            }
        }
    }
}
