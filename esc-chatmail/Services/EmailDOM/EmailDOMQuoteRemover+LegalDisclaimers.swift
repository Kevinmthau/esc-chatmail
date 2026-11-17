import Foundation
import SwiftSoup

// MARK: - Trailing legal disclaimer
//
// Truncates a legal disclaimer that ends the message, as `LegalDisclaimerPolicy`
// recognizes one. Runs in `.quotedAndSignatures` only, first of the text passes. Ahead
// of the signature markers, because "If you are not the intended recipient" is one of
// them and cuts in the middle of the paragraph, leaving the disclaimer's first sentences
// in the bubble; ahead of the trailing contact signature, so a contact block that the
// disclaimer followed is the message's tail again when that pass looks for it.
extension EmailDOMQuoteRemover {

    static func truncateTrailingLegalDisclaimer(in document: Document) throws {
        guard let body = document.body() else { return }
        let lines = inlineHeaderLines(in: body, splitBlockLines: true)
        guard let startIndex = LegalDisclaimerPolicy.trailingDisclaimerStartLine(in: lines.map(\.text)),
              let boundary = lines[startIndex].startTextNode else { return }
        // Truncation removes everything after the boundary. An authored image after the
        // disclaimer is content; a logo or tracking pixel belongs to it.
        if try containsMediaAfterSignature(boundary, in: body) { return }
        try truncateAtTextNode(
            boundary,
            matchStartUTF16: lines[startIndex].startUTF16Offset,
            in: boundary.getWholeText()
        )
    }
}
