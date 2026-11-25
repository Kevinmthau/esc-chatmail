import Foundation

enum HTMLMeaningfulContentChecker {
    private static let maxHiddenElementStripPasses = 4

    /// The hidden-element rules (an explicit `hidden` attribute; a style that
    /// does not render; the hidden-class conventions of email templates) are
    /// `HiddenElementRule.meaningfulContentRules`, and the comment and head
    /// rules `HTMLBlockRule`s: each removes what its regex did, read once. The
    /// regexes read to the end of the text at every start with nothing to
    /// close it, and SwiftSoup writes `<` and `>` in attribute values back out
    /// as they came, so markup a sender hid in one attribute reached them
    /// after every cleanup mode (an attribute of 5,000 `<a style='display:none'>`
    /// cost 8 s at 120 KB, of 10,000 `<!--` 4 s at 40 KB).
    private static let htmlCommentRule = HTMLBlockRule(
        start: "<!--",
        close: "-->",
        readsToTagEnd: false,
        options: [.caseInsensitive]
    )

    private static let headElementRule = HTMLBlockRule(
        start: "<head\\b",
        close: "</head>",
        readsToTagEnd: true,
        options: [.caseInsensitive]
    )

    private static let invisibleCharacterRegex: NSRegularExpression? = {
        try? NSRegularExpression(
            pattern: "[\\u200B\\u200C\\u200D\\uFEFF\\u00A0\\s]+",
            options: []
        )
    }()

    static func hasMeaningfulContent(_ html: String) -> Bool {
        let trimmed = html.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        let renderableHTML = stripNonRenderableContent(from: trimmed)
        let renderableTrimmed = renderableHTML.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !renderableTrimmed.isEmpty else { return false }

        // Image-only templates are still meaningful content.
        if renderableHTML.range(of: "<img", options: .caseInsensitive) != nil ||
            renderableHTML.range(of: "<svg", options: .caseInsensitive) != nil ||
            renderableHTML.range(of: "background-image", options: .caseInsensitive) != nil {
            return true
        }

        let extracted = TextProcessing.extractPlainText(from: renderableHTML)
        let normalized = normalizeInvisibleText(extracted)
        return !normalized.isEmpty
    }

    static func renderableHTML(from html: String) -> String {
        stripNonRenderableContent(from: html)
    }

    private static func stripNonRenderableContent(from html: String) -> String {
        var filtered = htmlCommentRule?.removingBlocks(from: html) ?? html
        filtered = headElementRule?.removingBlocks(from: filtered) ?? filtered

        for rule in HiddenElementRule.meaningfulContentRules {
            for _ in 0..<maxHiddenElementStripPasses {
                let updated = rule.removing(from: filtered)
                guard updated != filtered else {
                    break
                }

                filtered = updated
            }
        }

        return filtered
    }

    private static func normalizeInvisibleText(_ text: String) -> String {
        var normalized = text
            .replacingOccurrences(of: "\u{200B}", with: "")
            .replacingOccurrences(of: "\u{200C}", with: "")
            .replacingOccurrences(of: "\u{200D}", with: "")
            .replacingOccurrences(of: "\u{FEFF}", with: "")
            .replacingOccurrences(of: "\u{00A0}", with: " ")

        if let regex = invisibleCharacterRegex {
            let range = NSRange(location: 0, length: normalized.utf16.count)
            normalized = regex.stringByReplacingMatches(in: normalized, options: [], range: range, withTemplate: "")
        }

        return normalized.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
