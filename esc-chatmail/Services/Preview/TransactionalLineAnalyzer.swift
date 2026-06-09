import Foundation

/// Produces the cleaned preview lines for a transactional email, choosing
/// between the plain-text body and the HTML-derived text by a transactional
/// quality score.
///
/// Extracted from `TransactionalPreviewBuilder` so the line-preparation and
/// source-selection logic lives in one focused, independently testable unit. The
/// shared predicates it relies on — footer detection via `PreviewLineProcessor`,
/// plus the builder's `shouldSkipLine` / `transactionLine` / `firstAmount`
/// helpers — are injected so the analyzer carries no builder state.
struct TransactionalLineAnalyzer {
    private let lineProcessor: PreviewLineProcessor
    private let shouldSkipLine: (String) -> Bool
    private let transactionLine: ([String], [String?]) -> String?
    private let firstAmount: (String?) -> String?

    init(
        lineProcessor: PreviewLineProcessor,
        shouldSkipLine: @escaping (String) -> Bool,
        transactionLine: @escaping ([String], [String?]) -> String?,
        firstAmount: @escaping (String?) -> String?
    ) {
        self.lineProcessor = lineProcessor
        self.shouldSkipLine = shouldSkipLine
        self.transactionLine = transactionLine
        self.firstAmount = firstAmount
    }

    /// The preferred preview lines: body vs HTML-derived text, whichever scores
    /// higher for transactional content (HTML must beat the body by 4 to win).
    func cleanedLines(plainText: String?, canonicalHTML: String, extractedText: String? = nil) -> [String] {
        let bodyLines = previewLines(from: plainText ?? "")
        let htmlText = PreviewTextUtilities.normalizedPreviewText(extractedText)
            ?? PreviewTextUtilities.normalizedText(TextProcessing.extractPlainText(from: canonicalHTML))
        let htmlLines = previewLines(from: htmlText)

        guard !bodyLines.isEmpty else {
            return htmlLines
        }

        guard !htmlLines.isEmpty else {
            return bodyLines
        }

        let bodyScore = transactionalQualityScore(for: bodyLines)
        let htmlScore = transactionalQualityScore(for: htmlLines)
        return htmlScore >= bodyScore + 4 ? htmlLines : bodyLines
    }

    private func previewLines(from rawText: String) -> [String] {
        guard !rawText.isEmpty else { return [] }

        let rawLines = rawText.components(separatedBy: .newlines)
        var lines: [String] = []

        for line in rawLines {
            let normalizedLine = PreviewTextUtilities.normalizedText(line)
            guard !normalizedLine.isEmpty else {
                continue
            }

            if lineProcessor.shouldStopAtFooter(normalizedLine), !lines.isEmpty {
                break
            }

            if shouldSkipLine(normalizedLine) {
                continue
            }

            let comparable = PreviewTextUtilities.normalizedComparableText(normalizedLine)
            if lines.contains(where: { PreviewTextUtilities.normalizedComparableText($0) == comparable }) {
                continue
            }

            lines.append(normalizedLine)

            if lines.count >= 28 {
                break
            }
        }

        return lines
    }

    private func transactionalQualityScore(for lines: [String]) -> Int {
        var score = 0
        let joined = lines.joined(separator: "\n").lowercased()

        if firstAmount(joined) != nil {
            score += 24
        }

        if transactionLine(lines, []) != nil {
            score += 22
        }

        if joined.contains("status") {
            score += 8
        }

        if joined.contains("date") {
            score += 8
        }

        if joined.contains("transaction details") || joined.contains("order details") {
            score += 8
        }

        if lines.count >= 4 {
            score += 6
        }

        return score
    }
}
