import Foundation

enum OriginalEmailHTMLPreference: String, Sendable, Equatable {
    case automatic
    case preferHTML
}

struct EmailRenderQualityEvaluation: Sendable {
    enum Presentation: String, Sendable {
        case html
        case nativePlainText
    }

    let presentation: Presentation
    let fallbackText: String?
    let shouldOfferRawHTML: Bool
    let summary: String
}

struct EmailRenderQualityEvaluator {
    private let previewClassifier = EmailPreviewClassifier()

    func evaluate(
        html: String,
        plainText: String?,
        senderEmail: String?,
        subject: String?
    ) -> EmailRenderQualityEvaluation {
        let trimmedHTML = html.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedHTML.isEmpty else {
            return .useHTML(summary: "html_empty")
        }

        let classification = previewClassifier.classify(
            canonicalHTML: trimmedHTML,
            bodyText: plainText,
            senderEmail: senderEmail,
            subject: subject,
            includeTestFlightAvailabilitySignal: false
        )

        let renderableHTML = HTMLMeaningfulContentChecker.renderableHTML(from: trimmedHTML)
        let visibleHTMLText = normalizedText(TextProcessing.extractPlainText(from: renderableHTML))
        let normalizedPlainText = normalizedText(plainText ?? "")
        let lowercasedRenderableHTML = renderableHTML.lowercased()

        let tableCount = countOccurrences(of: "<table", in: lowercasedRenderableHTML)
        let imageCount = countOccurrences(of: "<img", in: lowercasedRenderableHTML)
        let semanticTagCount = countSemanticTags(in: lowercasedRenderableHTML)
        let tagCount = countTagLikeMarkup(in: renderableHTML)
        let spacerSignalCount = countRegexMatches(Self.largeSpacerRegexes, in: renderableHTML)
        let hiddenPrimaryContentCount =
            countRegexMatches(Self.hiddenPrimaryContentDocumentRegexes, in: trimmedHTML) +
            countRegexMatches(Self.hiddenPrimaryContentRenderableRegexes, in: renderableHTML)
        let footerLineRatio = ratioOfFooterLikeLines(in: visibleHTMLText)
        let markupToVisibleTextRatio = Double(renderableHTML.count) / Double(max(visibleHTMLText.count, 1))
        let plainTextScore = scoreTextCandidate(normalizedPlainText, kind: classification.kind)
        let visibleHTMLTextScore = scoreTextCandidate(visibleHTMLText, kind: classification.kind)

        var htmlRiskScore = 0

        if tableCount >= 8 {
            htmlRiskScore += 8
        }
        if tableCount >= 12 && semanticTagCount <= 4 {
            htmlRiskScore += 8
        }
        if tagCount >= 220 && visibleHTMLText.count <= 220 {
            htmlRiskScore += 5
        }
        if markupToVisibleTextRatio >= 28 {
            htmlRiskScore += 7
        }
        if markupToVisibleTextRatio >= 45 {
            htmlRiskScore += 6
        }
        if spacerSignalCount >= 2 {
            htmlRiskScore += 6
        }
        if spacerSignalCount >= 5 {
            htmlRiskScore += 8
        }
        if hiddenPrimaryContentCount > 0 {
            if plainTextScore >= visibleHTMLTextScore || visibleHTMLText.count < 140 {
                htmlRiskScore += 18
            } else {
                htmlRiskScore += 8
            }
        }
        if imageCount >= 3 && visibleHTMLText.count < 120 {
            htmlRiskScore += 5
        }
        if footerLineRatio >= 0.45 && visibleHTMLText.count < 220 {
            htmlRiskScore += 6
        }
        if normalizedPlainText.count >= max(140, visibleHTMLText.count * 2) {
            htmlRiskScore += 8
        } else if plainTextScore >= visibleHTMLTextScore + 4 {
            htmlRiskScore += 5
        }

        switch classification.kind {
        case .transactional:
            htmlRiskScore += 6
        case .newsletter:
            htmlRiskScore -= 8
        case .personToPerson:
            break
        }

        let threshold: Int
        switch classification.kind {
        case .transactional:
            threshold = 18
        case .newsletter:
            threshold = 30
        case .personToPerson:
            threshold = 24
        }

        guard htmlRiskScore >= threshold else {
            return .useHTML(
                summary: "keep_html risk=\(htmlRiskScore) threshold=\(threshold) kind=\(classification.kind.rawValue)"
            )
        }

        guard let fallbackText = preferredFallbackText(
            plainText: normalizedPlainText,
            plainTextScore: plainTextScore,
            visibleHTMLText: visibleHTMLText,
            visibleHTMLTextScore: visibleHTMLTextScore,
            kind: classification.kind
        ) else {
            return .useHTML(
                summary: "keep_html_no_fallback risk=\(htmlRiskScore) threshold=\(threshold) kind=\(classification.kind.rawValue)"
            )
        }

        return .nativePlainText(
            fallbackText,
            summary: """
            fallback risk=\(htmlRiskScore) threshold=\(threshold) kind=\(classification.kind.rawValue) \
            tables=\(tableCount) markup_ratio=\(Int(markupToVisibleTextRatio.rounded())) \
            spacers=\(spacerSignalCount) hidden_primary=\(hiddenPrimaryContentCount) \
            plain_score=\(plainTextScore) html_text_score=\(visibleHTMLTextScore)
            """
        )
    }

    private func preferredFallbackText(
        plainText: String,
        plainTextScore: Int,
        visibleHTMLText: String,
        visibleHTMLTextScore: Int,
        kind: EmailPreviewKind
    ) -> String? {
        if !plainText.isEmpty && plainTextScore >= max(visibleHTMLTextScore, 6) {
            return plainText
        }

        if !visibleHTMLText.isEmpty && visibleHTMLTextScore >= 6 {
            return visibleHTMLText
        }

        if kind == .transactional {
            if !plainText.isEmpty {
                return plainText
            }
            if !visibleHTMLText.isEmpty {
                return visibleHTMLText
            }
        }

        if !plainText.isEmpty && plainText.count >= 60 {
            return plainText
        }

        if !visibleHTMLText.isEmpty && visibleHTMLText.count >= 60 {
            return visibleHTMLText
        }

        return nil
    }

    private func normalizedText(_ text: String) -> String {
        guard !text.isEmpty else { return "" }

        return HTMLEntityDecoder.decode(text)
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\u{00A0}", with: " ")
            .replacingOccurrences(of: "[ \\t]+", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\\n[ \\t]+", with: "\n", options: .regularExpression)
            .replacingOccurrences(of: "[ \\t]+\\n", with: "\n", options: .regularExpression)
            .replacingOccurrences(of: "\\n{3,}", with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func scoreTextCandidate(_ text: String, kind: EmailPreviewKind) -> Int {
        guard !text.isEmpty else { return 0 }

        let lines = text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard !lines.isEmpty else { return 0 }

        let informativeLineCount = lines.filter { line in
            line.contains(where: { $0.isLetter }) && line.count >= 6
        }.count
        let urlOnlyLineCount = lines.filter { Self.urlOnlyLineRegex.firstMatch(in: $0, options: [], range: NSRange($0.startIndex..., in: $0)) != nil }.count
        let fieldLineCount = lines.filter { line in
            let lowercased = line.lowercased()
            return line.contains(":") || Self.transactionFieldHints.contains { lowercased.contains($0) }
        }.count

        var score = 0

        if text.count >= 80 {
            score += 4
        }
        if text.count >= 160 {
            score += 4
        }
        if informativeLineCount >= 3 {
            score += 4
        }
        if informativeLineCount >= 6 {
            score += 2
        }
        if fieldLineCount >= 2 {
            score += 4
        }
        if fieldLineCount >= 4 {
            score += 2
        }
        if text.contains(where: { $0.isLetter }) && text.contains(where: { $0.isNumber }) {
            score += 2
        }
        if kind == .transactional {
            let lowercased = text.lowercased()
            if Self.transactionFieldHints.contains(where: lowercased.contains) {
                score += 3
            }
        }
        if !lines.isEmpty && Double(urlOnlyLineCount) / Double(lines.count) > 0.5 {
            score -= 4
        }
        if ratioOfFooterLikeLines(in: text) > 0.5 {
            score -= 3
        }

        return max(score, 0)
    }

    private func countSemanticTags(in lowercasedHTML: String) -> Int {
        Self.semanticTags.reduce(into: 0) { count, token in
            count += countOccurrences(of: token, in: lowercasedHTML)
        }
    }

    private func countTagLikeMarkup(in html: String) -> Int {
        countRegexMatches(Self.tagRegex, in: html)
    }

    private func countOccurrences(of token: String, in text: String) -> Int {
        guard !token.isEmpty else { return 0 }
        return text.components(separatedBy: token).count - 1
    }

    private func ratioOfFooterLikeLines(in text: String) -> Double {
        let lines = text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }

        guard !lines.isEmpty else { return 0 }

        let footerLines = lines.filter { line in
            Self.footerLineHints.contains { line.contains($0) }
        }.count

        return Double(footerLines) / Double(lines.count)
    }

    private func countRegexMatches(_ regexes: [NSRegularExpression], in text: String) -> Int {
        regexes.reduce(into: 0) { count, regex in
            count += countRegexMatches(regex, in: text)
        }
    }

    private func countRegexMatches(_ regex: NSRegularExpression, in text: String) -> Int {
        let range = NSRange(text.startIndex..., in: text)
        return regex.numberOfMatches(in: text, options: [], range: range)
    }

    private static let semanticTags = [
        "<p",
        "<h1",
        "<h2",
        "<h3",
        "<h4",
        "<h5",
        "<h6",
        "<li",
        "<ul",
        "<ol",
        "<article",
        "<section",
        "<main"
    ]

    private static let footerLineHints = [
        "unsubscribe",
        "manage preferences",
        "privacy policy",
        "view in browser",
        "view online",
        "do not reply",
        "do-not-reply",
        "all rights reserved",
        "mailing address",
        "terms of use",
        "security center"
    ]

    private static let transactionFieldHints = [
        "amount",
        "date",
        "status",
        "tracking",
        "order",
        "receipt",
        "invoice",
        "account",
        "verification",
        "code",
        "security",
        "payment"
    ]

    private static let tagRegex: NSRegularExpression = {
        // swiftlint:disable:next force_try
        try! NSRegularExpression(pattern: "<[a-zA-Z][^>]*>", options: [])
    }()

    private static let urlOnlyLineRegex: NSRegularExpression = {
        // swiftlint:disable:next force_try
        try! NSRegularExpression(pattern: #"^\s*https?://\S+\s*$"#, options: [.caseInsensitive])
    }()

    private static let largeSpacerRegexes: [NSRegularExpression] = [
        // swiftlint:disable:next force_try
        try! NSRegularExpression(
            pattern: #"<(?:td|tr|div|table|p)\b[^>]*\bheight\s*=\s*["']?(?:4[0-9]|[5-9][0-9]|\d{3,})"#,
            options: [.caseInsensitive]
        ),
        // swiftlint:disable:next force_try
        try! NSRegularExpression(
            pattern: #"style\s*=\s*["'][^"']*(?:min-)?height\s*:\s*(?:4[0-9]|[5-9][0-9]|\d{3,})px"#,
            options: [.caseInsensitive]
        ),
        // swiftlint:disable:next force_try
        try! NSRegularExpression(
            pattern: #"<(?:td|div|p)\b[^>]*>\s*(?:&nbsp;|&#160;|\s|<br\s*/?>){8,}\s*</(?:td|div|p)>"#,
            options: [.caseInsensitive]
        )
    ]

    private static let hiddenPrimaryContentDocumentRegexes: [NSRegularExpression] = [
        // swiftlint:disable:next force_try
        try! NSRegularExpression(
            pattern: #"(?:\.|#)[^{}\n>]*(?:action|button|cta|primary)[^{}\n>]*\{[^}]*display\s*:\s*none"#,
            options: [.caseInsensitive]
        )
    ]

    private static let hiddenPrimaryContentRenderableRegexes: [NSRegularExpression] = [
        // swiftlint:disable:next force_try
        try! NSRegularExpression(
            pattern: #"<(?:a|table|div|td)\b[^>]*(?:class|id)\s*=\s*["'][^"']*(?:action|button|cta|primary)[^"']*["'][^>]*style\s*=\s*["'][^"']*(?:display\s*:\s*none|visibility\s*:\s*hidden)"#,
            options: [.caseInsensitive]
        ),
        // swiftlint:disable:next force_try
        try! NSRegularExpression(
            pattern: #"<a\b[^>]*style\s*=\s*["'][^"']*(?:display\s*:\s*none|visibility\s*:\s*hidden)"#,
            options: [.caseInsensitive]
        )
    ]
}

private extension EmailRenderQualityEvaluation {
    static func useHTML(summary: String) -> Self {
        Self(
            presentation: .html,
            fallbackText: nil,
            shouldOfferRawHTML: false,
            summary: summary
        )
    }

    static func nativePlainText(_ text: String, summary: String) -> Self {
        Self(
            presentation: .nativePlainText,
            fallbackText: text,
            shouldOfferRawHTML: true,
            summary: summary
        )
    }
}
