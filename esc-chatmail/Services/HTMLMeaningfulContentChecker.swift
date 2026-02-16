import Foundation

enum HTMLMeaningfulContentChecker {
    static func hasMeaningfulContent(_ html: String) -> Bool {
        let trimmed = html.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        // Image-only templates are still meaningful content.
        if html.range(of: "<img", options: .caseInsensitive) != nil ||
            html.range(of: "<svg", options: .caseInsensitive) != nil ||
            html.range(of: "background-image", options: .caseInsensitive) != nil {
            return true
        }

        let extracted = TextProcessing.extractPlainText(from: html)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return !extracted.isEmpty
    }
}
