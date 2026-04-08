import Foundation

struct NewsletterPreviewBuilder {
    func buildPreview(
        canonicalHTML: String,
        bodyText: String?,
        cleanedSnippet: String? = nil,
        senderName: String? = nil,
        senderEmail: String?,
        subject: String? = nil
    ) -> NewsletterPreviewModel? {
        let sourceDomain = normalizedSourceDomain(from: senderEmail)
        let sourceLabel = sourceLabel(senderName: senderName, sourceDomain: sourceDomain)
        let title = resolvedTitle(from: canonicalHTML, subject: subject)
        let lines = cleanedPreviewLines(bodyText: bodyText, canonicalHTML: canonicalHTML)
        let subtitle = resolvedSubtitle(from: lines, excluding: [title, subject, sourceLabel, sourceDomain])
        let snippet = resolvedSnippet(
            preferredSnippet: cleanedSnippet,
            from: lines,
            excluding: [title, subtitle, subject, sourceLabel, sourceDomain]
        )
        let heroImageURL = bestHeroImageURL(from: canonicalHTML)

        guard title != nil || subtitle != nil || snippet != nil || heroImageURL != nil else {
            return nil
        }

        let normalizedSubject = normalizedText(subject)
        let fallbackSubject = normalizedSubject.isEmpty ? nil : normalizedSubject
        let resolvedTitle = title ?? fallbackSubject ?? sourceLabel ?? "Newsletter"
        let resolvedSnippet = snippet ?? subtitle ?? sourceDomain ?? "Open the full email to view the complete message."

        return NewsletterPreviewModel(
            title: resolvedTitle,
            subtitle: subtitle,
            snippet: truncate(resolvedSnippet, limit: 220),
            heroImageURL: heroImageURL,
            sourceLabel: sourceLabel,
            sourceDomain: sourceDomain
        )
    }

    private func resolvedTitle(from canonicalHTML: String, subject: String?) -> String? {
        let candidates = [
            firstTagText("h1", in: canonicalHTML),
            firstTagText("h2", in: canonicalHTML),
            firstPreheaderText(in: canonicalHTML),
            firstTagText("title", in: canonicalHTML),
            normalizedText(subject)
        ]

        for candidate in candidates {
            guard let candidate, isMeaningfulTitle(candidate) else {
                continue
            }
            return truncate(candidate, limit: 120)
        }

        return nil
    }

    private func resolvedSubtitle(from lines: [String], excluding excluded: [String?]) -> String? {
        let excludedValues = normalizedSet(from: excluded)

        for line in lines {
            let comparable = normalizedComparableText(line)
            guard !excludedValues.contains(comparable),
                  line.count >= 18,
                  line.count <= 55 else {
                continue
            }

            return truncate(line, limit: 110)
        }

        return nil
    }

    private func resolvedSnippet(
        preferredSnippet: String?,
        from lines: [String],
        excluding excluded: [String?]
    ) -> String? {
        let excludedValues = normalizedSet(from: excluded)

        if let preferredSnippet = normalizedPreviewSummary(preferredSnippet, excluding: excludedValues) {
            return truncate(preferredSnippet, limit: 190)
        }

        var collected: [String] = []

        for line in lines {
            let comparable = normalizedComparableText(line)
            guard !excludedValues.contains(comparable) else {
                continue
            }

            if collected.isEmpty && line.count < 30 {
                continue
            }

            collected.append(line)
            let joined = collected.joined(separator: " ")
            if joined.count >= 170 {
                return truncate(joined, limit: 190)
            }
        }

        let joined = collected.joined(separator: " ")
        return joined.isEmpty ? nil : truncate(joined, limit: 190)
    }

    private func cleanedPreviewLines(bodyText: String?, canonicalHTML: String) -> [String] {
        let bodyLines = previewLines(from: normalizedBodyText(bodyText) ?? "")
        let htmlLines = previewLines(from: normalizedText(TextProcessing.extractPlainText(from: canonicalHTML)))

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

    private func previewLines(from rawText: String) -> [String] {
        guard !rawText.isEmpty else { return [] }

        let rawLines = rawText.components(separatedBy: .newlines)
        var lines: [String] = []

        for line in rawLines {
            let normalizedLine = normalizedText(line)
            guard !normalizedLine.isEmpty else {
                continue
            }

            if shouldStopAtFooter(normalizedLine), !lines.isEmpty {
                break
            }

            if shouldSkipLine(normalizedLine) {
                continue
            }

            if lines.contains(where: { normalizedComparableText($0) == normalizedComparableText(normalizedLine) }) {
                continue
            }

            lines.append(normalizedLine)

            if lines.count >= 10 {
                break
            }
        }

        return lines
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

    private func bestHeroImageURL(from canonicalHTML: String) -> String? {
        let regex = try? NSRegularExpression(pattern: "<img\\b[^>]*>", options: [.caseInsensitive])
        let nsRange = NSRange(canonicalHTML.startIndex..., in: canonicalHTML)
        let matches = regex?.matches(in: canonicalHTML, options: [], range: nsRange) ?? []

        var bestCandidate: (url: String, score: Int)?

        for (index, match) in matches.prefix(8).enumerated() {
            guard let range = Range(match.range, in: canonicalHTML) else {
                continue
            }

            let tag = String(canonicalHTML[range])
            guard let source = attributeValue(named: "src", in: tag),
                  isRenderableRemoteImageURL(source) else {
                continue
            }

            let width = numericAttribute(named: "width", in: tag)
            let height = numericAttribute(named: "height", in: tag)
            let descriptor = [
                attributeValue(named: "alt", in: tag),
                attributeValue(named: "class", in: tag)
            ]
            .compactMap { $0?.lowercased() }
            .joined(separator: " ")

            var score = 30 - (index * 3)

            if let width, width >= 240 {
                score += 20
            }

            if let height, height >= 120 {
                score += 20
            }

            if width == nil && height == nil {
                score += 8
            }

            if descriptor.contains("hero") || descriptor.contains("banner") || descriptor.contains("cover") || descriptor.contains("feature") {
                score += 20
            }

            if descriptor.contains("logo") || descriptor.contains("icon") || descriptor.contains("avatar") || descriptor.contains("social") || descriptor.contains("spacer") {
                score -= 18
            }

            if source.lowercased().contains("hero") || source.lowercased().contains("banner") || source.lowercased().contains("cover") {
                score += 14
            }

            if source.lowercased().contains("logo") || source.lowercased().contains("icon") || source.lowercased().contains("avatar") || source.lowercased().contains("pixel") {
                score -= 18
            }

            if let width, width <= 80 {
                score -= 15
            }

            if let height, height <= 80 {
                score -= 15
            }

            guard score >= 18 else {
                continue
            }

            if bestCandidate == nil || score > (bestCandidate?.score ?? Int.min) {
                bestCandidate = (source, score)
            }
        }

        return bestCandidate?.url
    }

    private func firstTagText(_ tagName: String, in html: String) -> String? {
        let pattern = "<\(tagName)\\b[^>]*>([\\s\\S]*?)</\(tagName)>"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: html, options: [], range: NSRange(html.startIndex..., in: html)),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: html) else {
            return nil
        }

        return normalizedText(TextProcessing.extractPlainText(from: String(html[range])))
    }

    private func firstPreheaderText(in html: String) -> String? {
        let pattern = "<(?:div|span)\\b[^>]*class\\s*=\\s*[\"'][^\"']*preheader[^\"']*[\"'][^>]*>([\\s\\S]*?)</(?:div|span)>"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: html, options: [], range: NSRange(html.startIndex..., in: html)),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: html) else {
            return nil
        }

        let extracted = normalizedText(TextProcessing.extractPlainText(from: String(html[range])))
        return shouldSkipLine(extracted) || shouldStopAtFooter(extracted) ? nil : extracted
    }

    private func attributeValue(named attribute: String, in tag: String) -> String? {
        let pattern = "\(attribute)\\s*=\\s*(?:\"([^\"]+)\"|'([^']+)'|([^\\s>]+))"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: tag, options: [], range: NSRange(tag.startIndex..., in: tag)) else {
            return nil
        }

        for index in 1..<match.numberOfRanges {
            guard let range = Range(match.range(at: index), in: tag) else {
                continue
            }

            let value = normalizedText(String(tag[range]))
            if !value.isEmpty {
                return value
            }
        }

        return nil
    }

    private func numericAttribute(named attribute: String, in tag: String) -> Int? {
        guard let value = attributeValue(named: attribute, in: tag) else {
            return nil
        }

        return Int(value.replacingOccurrences(of: "[^0-9]", with: "", options: .regularExpression))
    }

    private func isRenderableRemoteImageURL(_ url: String) -> Bool {
        let lowercased = url.lowercased()
        guard !lowercased.isEmpty,
              !lowercased.hasPrefix("cid:"),
              !lowercased.hasPrefix("data:"),
              !lowercased.contains("about:blank") else {
            return false
        }

        return lowercased.hasPrefix("http://") || lowercased.hasPrefix("https://")
    }

    private func normalizedSourceDomain(from senderEmail: String?) -> String? {
        guard let senderEmail = senderEmail?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !senderEmail.isEmpty else {
            return nil
        }

        let extractedEmail = EmailNormalizer.extractEmail(from: senderEmail) ?? senderEmail
        guard let atIndex = extractedEmail.lastIndex(of: "@"),
              atIndex < extractedEmail.index(before: extractedEmail.endIndex) else {
            return nil
        }

        let domain = extractedEmail[extractedEmail.index(after: atIndex)...]
            .lowercased()
            .replacingOccurrences(of: "^www\\.", with: "", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: " <>\"'()[],:;"))

        return domain.isEmpty ? nil : domain
    }

    private func sourceLabel(senderName: String?, sourceDomain: String?) -> String? {
        if let senderName = normalizedSenderName(senderName) {
            return truncate(senderName, limit: 40)
        }

        guard let sourceDomain, !sourceDomain.isEmpty else {
            return nil
        }

        let primarySegment = sourceDomain
            .split(separator: ".")
            .map(String.init)
            .first(where: { segment in
                let lowercased = segment.lowercased()
                return lowercased.count > 1 && !ignoredSourceSubdomains.contains(lowercased)
            })?
            .replacingOccurrences(of: "-", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard let primarySegment, !primarySegment.isEmpty else {
            return nil
        }

        return primarySegment.capitalized
    }

    private func normalizedSenderName(_ senderName: String?) -> String? {
        let normalized = normalizedText(senderName)
        guard !normalized.isEmpty,
              !normalized.contains("@") else {
            return nil
        }

        return normalized
    }

    private func normalizedBodyText(_ bodyText: String?) -> String? {
        guard let bodyText else { return nil }
        return normalizedText(RawEmailSourceSanitizer.extractDisplayText(from: bodyText))
    }

    private func normalizedSet(from strings: [String?]) -> Set<String> {
        Set(strings.compactMap { value in
            guard let value = value else { return nil }
            let normalized = normalizedComparableText(value)
            return normalized.isEmpty ? nil : normalized
        })
    }

    private func normalizedComparableText(_ text: String) -> String {
        normalizedText(text).lowercased()
    }

    private func normalizedPreviewSummary(_ text: String?, excluding excludedValues: Set<String>) -> String? {
        let normalized = normalizedText(text)
        guard !normalized.isEmpty,
              normalized.count >= 24,
              !lineLooksLikePreviewNoise(normalized),
              !shouldSkipLine(normalized),
              !shouldStopAtFooter(normalized) else {
            return nil
        }

        let comparable = normalizedComparableText(normalized)
        guard !excludedValues.contains(comparable) else {
            return nil
        }

        return normalized
    }

    private func normalizedText(_ text: String?) -> String {
        guard let text else { return "" }
        return HTMLEntityDecoder.decode(text)
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "[ \\t]+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func shouldSkipLine(_ line: String) -> Bool {
        let lowercased = line.lowercased()

        if lowercased.count < 4 {
            return true
        }

        if lineLooksLikePreviewNoise(line) {
            return true
        }

        if lowercased.hasPrefix("http://") || lowercased.hasPrefix("https://") {
            return true
        }

        return ignoredLinePatterns.contains { lowercased.contains($0) }
    }

    private func shouldStopAtFooter(_ line: String) -> Bool {
        let lowercased = line.lowercased()
        return footerStopPatterns.contains { lowercased.contains($0) }
    }

    private func lineLooksLikePreviewNoise(_ line: String) -> Bool {
        let lowercased = line.lowercased()

        if lowercased.contains("{") && lowercased.contains("}") && lowercased.contains(":") {
            return true
        }

        if lowercased.range(of: "^[\\d\\W]{1,6}$", options: .regularExpression) != nil {
            return true
        }

        if line.range(of: "<[^>]+>", options: .regularExpression) != nil {
            return true
        }

        if line.range(of: "&#(?:x?[0-9a-fA-F]+);", options: .regularExpression) != nil {
            return true
        }

        if lowercased.range(
            of: "[a-z-]+\\s*:\\s*[^;]+;\\s*[a-z-]+\\s*:",
            options: [.regularExpression, .caseInsensitive]
        ) != nil {
            return true
        }

        return previewNoisePatterns.contains { lowercased.contains($0) }
    }

    private func isMeaningfulTitle(_ title: String) -> Bool {
        let normalized = normalizedText(title)
        guard normalized.count >= 12 else {
            return false
        }

        let lowercased = normalized.lowercased()
        guard !ignoredTitlePatterns.contains(where: { lowercased.contains($0) }) else {
            return false
        }

        return true
    }

    private func truncate(_ text: String, limit: Int) -> String {
        guard text.count > limit else {
            return text
        }

        let truncated = String(text.prefix(limit))
        if let lastSpace = truncated.lastIndex(of: " "),
           truncated.distance(from: truncated.startIndex, to: lastSpace) > limit - 32 {
            return String(truncated[..<lastSpace]) + "..."
        }

        return truncated + "..."
    }
}

private let footerStopPatterns = [
    "unsubscribe",
    "manage preferences",
    "manage subscriptions",
    "join our community",
    "view in browser",
    "view online",
    "terms and conditions",
    "privacy policy",
    "questions? contact us",
    "why did i get this email",
    "all rights reserved"
]

private let ignoredLinePatterns = [
    "follow us",
    "facebook",
    "instagram",
    "linkedin",
    "twitter",
    "mastodon",
    "threads",
    "join our community",
    "questions? contact us",
    "free shipping on orders",
    "valid within the contiguous united states",
    "view in browser",
    "view online",
    "unsubscribe",
    "manage preferences",
    "manage subscriptions",
    "terms and conditions",
    "privacy policy",
    "terms of service",
    "all rights reserved",
    "mailing address",
    "copyright"
]

private let ignoredTitlePatterns = [
    "view in browser",
    "unsubscribe",
    "manage preferences"
]

private let previewNoisePatterns = [
    "box-sizing",
    "content-type:",
    "content-transfer-encoding:",
    "mime-version:",
    "charset=",
    "font-family:",
    "max-height:",
    "mso-",
    "padding:",
    "style=",
    "target=",
    "text-decoration:",
    "visibility:",
    "#messageviewbody"
]

private let ignoredSourceSubdomains: Set<String> = [
    "cdn",
    "click",
    "e",
    "email",
    "em",
    "img",
    "image",
    "links",
    "m",
    "mail",
    "mailer",
    "news",
    "newsletter",
    "notifications",
    "notify",
    "track",
    "tracking",
    "updates",
    "www"
]
