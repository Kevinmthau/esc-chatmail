import Foundation

/// Produces the cleaned preview lines for a newsletter email, choosing between
/// the plain-text body and the HTML-derived text by a newsletter quality score,
/// and exposing the per-source line preparation used both for that choice and by
/// the hero-image context scoring.
///
/// Extracted from `NewsletterPreviewBuilder` so the line-preparation and
/// source-selection logic lives in one focused, independently testable unit. The
/// shared predicates it relies on — footer detection via `PreviewLineProcessor`,
/// plus the builder's `shouldSkipLine` / `lineLooksLikePreviewNoise` helpers and
/// the leading-tracking-URL trimmer — are injected so the analyzer carries no
/// builder state.
struct NewsletterLineAnalyzer {
    private let lineProcessor: PreviewLineProcessor
    private let shouldSkipLine: (String) -> Bool
    private let lineLooksLikePreviewNoise: (String) -> Bool
    private let trimmingLeadingPreviewURLNoise: (String, Bool) -> String

    init(
        lineProcessor: PreviewLineProcessor,
        shouldSkipLine: @escaping (String) -> Bool,
        lineLooksLikePreviewNoise: @escaping (String) -> Bool,
        trimmingLeadingPreviewURLNoise: @escaping (String, Bool) -> String
    ) {
        self.lineProcessor = lineProcessor
        self.shouldSkipLine = shouldSkipLine
        self.lineLooksLikePreviewNoise = lineLooksLikePreviewNoise
        self.trimmingLeadingPreviewURLNoise = trimmingLeadingPreviewURLNoise
    }

    /// The preferred preview lines: body vs HTML-derived text, whichever scores
    /// higher for newsletter content (HTML must beat the body by 8 to win).
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

        let bodyScore = previewQualityScore(for: bodyLines)
        let htmlScore = previewQualityScore(for: htmlLines)
        return htmlScore >= bodyScore + 8 ? htmlLines : bodyLines
    }

    func previewLines(from rawText: String) -> [String] {
        guard !rawText.isEmpty else { return [] }

        let rawLines = rawText.components(separatedBy: .newlines)
        var lines: [String] = []
        var leadingURLFallbackLines: [String] = []

        for line in rawLines {
            let normalizedLine = PreviewTextUtilities.normalizedText(line)
            guard !normalizedLine.isEmpty else {
                continue
            }

            let lineWithoutLeadingURL = trimmingLeadingPreviewURLNoise(normalizedLine, true)
            let usesLeadingURLFallback = lineWithoutLeadingURL != normalizedLine
            let candidateLine = usesLeadingURLFallback ? lineWithoutLeadingURL : normalizedLine

            guard !candidateLine.isEmpty else {
                continue
            }

            if lineProcessor.shouldStopAtFooter(candidateLine), !lines.isEmpty || !leadingURLFallbackLines.isEmpty {
                break
            }

            if shouldSkipLine(candidateLine) {
                continue
            }

            if lines.contains(where: { PreviewTextUtilities.normalizedComparableText($0) == PreviewTextUtilities.normalizedComparableText(candidateLine) }) ||
                leadingURLFallbackLines.contains(where: { PreviewTextUtilities.normalizedComparableText($0) == PreviewTextUtilities.normalizedComparableText(candidateLine) }) {
                continue
            }

            if usesLeadingURLFallback {
                leadingURLFallbackLines.append(candidateLine)
            } else {
                lines.append(candidateLine)
            }

            if lines.count >= 10 {
                break
            }
        }

        if lines.isEmpty {
            return Array(leadingURLFallbackLines.prefix(10))
        }

        guard !leadingURLFallbackLines.isEmpty else {
            return lines
        }

        if lines.count < 10 {
            return lines + Array(leadingURLFallbackLines.prefix(10 - lines.count))
        }

        if lines.contains(where: { $0.count >= 30 }) {
            return lines
        }

        return Array(lines.prefix(9)) + Array(leadingURLFallbackLines.prefix(1))
    }

    private func previewQualityScore(for lines: [String]) -> Int {
        var score = 0

        for line in lines.prefix(4) {
            if lineLooksLikePreviewNoise(line) {
                score -= 40
                continue
            }

            if line.count >= 24 {
                score += 12
            } else if line.count >= 12 {
                score += 7
            } else {
                score += 2
            }

            if line.contains(" ") {
                score += 4
            }

            if line.range(of: "[.!?]$", options: .regularExpression) != nil {
                score += 3
            }
        }

        if lines.count >= 2 {
            score += 10
        }

        if lines.count >= 3 {
            score += 6
        }

        return score
    }
}
