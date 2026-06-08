import Foundation

// MARK: - Input shape detection
//
// Decides whether the input HTML is a full document or a bare fragment, so
// `removeQuotes(from:mode:)` can mirror the legacy contract (fragment in →
// fragment out). Pure string scanning; no DOM parse required.
extension EmailDOMQuoteRemover {

    static func hasDocumentWrapper(_ html: String) -> Bool {
        containsTagPrefix("<!doctype", in: html) ||
            containsTagPrefix("<html", in: html) ||
            containsTagPrefix("<head", in: html) ||
            containsTagPrefix("<body", in: html)
    }

    private static func containsTagPrefix(_ prefix: String, in html: String) -> Bool {
        var searchStart = html.startIndex

        while let range = html.range(
            of: prefix,
            options: .caseInsensitive,
            range: searchStart..<html.endIndex
        ) {
            let boundaryIndex = range.upperBound
            if boundaryIndex == html.endIndex || !isTagNameCharacter(html[boundaryIndex]) {
                return true
            }
            searchStart = boundaryIndex
        }

        return false
    }

    private static func isTagNameCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || character == "-" || character == ":" || character == "_"
    }
}
