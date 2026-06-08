import Foundation
import SwiftSoup

// MARK: - Footer containers (newsletter unsubscribe, social icons)
//
// Removes whole footer/social/unsubscribe blocks by class/id selector. Only
// runs in `.quotedAndSignatures` mode.
extension EmailDOMQuoteRemover {

    private static let footerSelectors: [String] = [
        "div[class*=footer]",
        "table[class*=footer]",
        "div[id*=footer]",
        "table[class*=social]",
        "div[class*=social]",
        "div[class*=unsubscribe]",
        "p[class*=unsubscribe]",
        "div[class*=sig]",
        "table[class*=signature]"
    ]

    static func removeFooterContainers(in document: Document) throws {
        for selector in footerSelectors {
            let elements = try document.select(selector)
            for element in elements.array() {
                try element.remove()
            }
        }
    }
}
