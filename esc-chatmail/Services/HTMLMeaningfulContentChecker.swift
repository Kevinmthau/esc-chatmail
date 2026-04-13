import Foundation

enum HTMLMeaningfulContentChecker {
    private static let hiddenElementRegexes: [NSRegularExpression] = {
        let patterns = [
            // Explicit hidden attribute.
            "<([a-zA-Z][a-zA-Z0-9]*)\\b[^>]*\\bhidden\\b[^>]*>[\\s\\S]*?</\\1>",
            // Inline style patterns that are genuinely non-rendered. Avoid treating
            // `font-size:0`/`line-height:0` as hidden by itself because many table-based
            // transactional templates use those on visible layout wrappers.
            "<([a-zA-Z][a-zA-Z0-9]*)\\b[^>]*style\\s*=\\s*['\"][^'\"]*(?:display\\s*:\\s*none|visibility\\s*:\\s*hidden|mso-hide\\s*:\\s*all|opacity\\s*:\\s*0(?:\\.0+)?)[^'\"]*['\"][^>]*>[\\s\\S]*?</\\1>",
            // Hidden class conventions seen in email templates.
            "<([a-zA-Z][a-zA-Z0-9]*)\\b[^>]*class\\s*=\\s*['\"][^'\"]*(?:\\bm-hide\\b|\\bpreheader\\b|\\bpreview-text\\b)[^'\"]*['\"][^>]*>[\\s\\S]*?</\\1>"
        ]

        return patterns.compactMap { pattern in
            try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
        }
    }()

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
        var filtered = html
            .replacingOccurrences(
                of: "<!--[\\s\\S]*?-->",
                with: "",
                options: [.regularExpression, .caseInsensitive]
            )
            .replacingOccurrences(
                of: "<head\\b[^>]*>[\\s\\S]*?</head>",
                with: "",
                options: [.regularExpression, .caseInsensitive]
            )

        for regex in hiddenElementRegexes {
            var didChange = true
            while didChange {
                let range = NSRange(location: 0, length: filtered.utf16.count)
                let updated = regex.stringByReplacingMatches(in: filtered, options: [], range: range, withTemplate: "")
                didChange = updated != filtered
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
