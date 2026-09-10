import Foundation

/// Recognizes otherwise unknown corporate footers by an exact repeat in quoted history.
/// Only the complete trailing block is eligible, so a new postscript stays visible.
enum RepeatedSignatureRemover {
    static func removeSignature(from text: String, quotedText: () -> String) -> String {
        let lines = TextProcessing.normalizeLineEndings(text).components(separatedBy: "\n")
        let nonEmpty = lines.indices.filter { !lines[$0].trimmingCharacters(in: .whitespaces).isEmpty }
        guard nonEmpty.count >= 6 else { return text }

        var normalizedHistory: String?
        // Work backward: "Thank you!" can precede the actual "Sincerely," closing.
        for position in nonEmpty.indices.reversed() {
            guard position > 0, position + 4 < nonEmpty.count else { continue }
            let start = nonEmpty[position]
            let name = nonEmpty[position + 1]
            // A colon introduces an authored example or template, even if it is repeated.
            guard !lines[nonEmpty[position - 1]].trimmingCharacters(in: .whitespaces).hasSuffix(":") else { continue }
            guard isSignOff(lines[start]), !isSignOff(lines[name]),
                  SignatureSignOffPolicy.shouldPreserveNameLine(lines[name]),
                  SignatureSignOffPolicy.isStrongSupportLine(lines[nonEmpty[position + 2]]) else { continue }
            guard !nonEmpty[(position + 2)...].contains(where: {
                PlainTextSignatureRemover.isPostscriptLine(lines[$0].lowercased())
            }) else { continue }

            let contactWindow = nonEmpty[(position + 3)..<min(nonEmpty.count, position + 15)]
            var contactCount = 0
            for index in contactWindow {
                let line = lines[index]
                if EmailDOMQuoteRemover.isTrailingSignatureContactLine(line) {
                    contactCount += 1
                } else if SignaturePatterns.supportProse?.firstMatch(
                    in: line, range: NSRange(line.startIndex..., in: line)
                ) != nil {
                    break
                }
            }
            guard contactCount >= 2 else { continue }

            if normalizedHistory == nil {
                normalizedHistory = " " + normalizedForComparison(quotedText()) + " "
            }
            let suffix = normalizedForComparison(lines[start...].joined(separator: "\n"))
            // Spaces bound the match to whole words, including the final word of the footer.
            guard let normalizedHistory, normalizedHistory.contains(" " + suffix + " ") else { continue }
            return lines[...name].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return text
    }

    private static func isSignOff(_ line: String) -> Bool {
        SignaturePatterns.signOffPhrases.contains(
            line.trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: .punctuationCharacters).lowercased()
        )
    }

    private static func normalizedForComparison(_ text: String) -> String {
        // Outlook's plain alternative adds link destinations to older quoted copies.
        let visibleText = text.replacingOccurrences(
            of: #"<(?:https?://|mailto:|tel:)[^<>\s]+>"#,
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )
        return visibleText.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
