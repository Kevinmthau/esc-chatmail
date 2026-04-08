import Foundation

struct NewsletterPreviewBuilder {
    private let sanitizer = HTMLSanitizerService.shared
    private let urlSanitizer = HTMLURLSanitizer()
    private let trackingRemover = HTMLTrackingRemover()

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
        let heroImage = bestHeroImageCandidate(from: canonicalHTML)
        let heroImageURL = heroImage?.url

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
            heroImageDisplayMode: heroImage?.displayMode ?? .fill,
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

        if let preferredSnippet = normalizedPreviewSummary(
            preferredSnippet,
            excluding: excluded,
            excludedValues: excludedValues
        ) {
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

    private func bestHeroImageCandidate(from canonicalHTML: String) -> HeroImageCandidate? {
        // Reuse the existing HTML safety pipeline before extracting any image candidate for the
        // native newsletter card so preview loading does not bypass URL sanitization/tracking rules.
        let sanitizedHTML = sanitizer.sanitize(canonicalHTML)
        let regex = try? NSRegularExpression(pattern: "<img\\b[^>]*>", options: [.caseInsensitive])
        let nsRange = NSRange(sanitizedHTML.startIndex..., in: sanitizedHTML)
        let matches = regex?.matches(in: sanitizedHTML, options: [], range: nsRange) ?? []

        var bestCandidate: HeroImageCandidate?

        for (index, match) in matches.prefix(8).enumerated() {
            guard let range = Range(match.range, in: sanitizedHTML) else {
                continue
            }

            let tag = String(sanitizedHTML[range])
            let width = numericAttribute(named: "width", in: tag)
            let height = numericAttribute(named: "height", in: tag)
            let descriptor = [
                attributeValue(named: "alt", in: tag),
                attributeValue(named: "class", in: tag)
            ]
            .compactMap { $0?.lowercased() }
            .joined(separator: " ")
            guard let source = attributeValue(named: "src", in: tag),
                  let safeSource = safeHeroImageURL(
                    from: source,
                    descriptor: descriptor,
                    width: width,
                    height: height
                  ) else {
                continue
            }
            let lowercasedSource = safeSource.lowercased()
            guard let displayMode = heroImageDisplayMode(
                width: width,
                height: height,
                descriptor: descriptor,
                url: lowercasedSource
            ) else {
                continue
            }

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

            if lowercasedSource.contains("hero") || lowercasedSource.contains("banner") || lowercasedSource.contains("cover") {
                score += 14
            }

            if lowercasedSource.contains("logo") || lowercasedSource.contains("icon") || lowercasedSource.contains("avatar") || lowercasedSource.contains("pixel") {
                score -= 18
            }

            if let width, width <= 80 {
                score -= 15
            }

            if let height, height <= 80 {
                score -= 15
            }

            // Keep very wide images available as a fallback, but prefer conventional hero images
            // when both are present.
            if displayMode == .fit {
                score -= 20
            }

            guard score >= 18 else {
                continue
            }

            let candidate = HeroImageCandidate(
                url: safeSource,
                displayMode: displayMode,
                score: score
            )
            if bestCandidate == nil || score > (bestCandidate?.score ?? Int.min) {
                bestCandidate = candidate
            }
        }

        return bestCandidate
    }

    private func safeHeroImageURL(
        from rawURL: String,
        descriptor: String,
        width: Int?,
        height: Int?
    ) -> String? {
        let normalizedURL = normalizedText(rawURL)
        let lowercasedURL = normalizedURL.lowercased()

        guard isRenderableRemoteImageURL(normalizedURL),
              urlSanitizer.isURLSafe(normalizedURL),
              !trackingRemover.isTrackingLikeImageURL(normalizedURL),
              !containsBlockedHeroHint(in: descriptor),
              !containsBlockedHeroHint(in: lowercasedURL),
              !isObviouslyTinyImage(width: width, height: height),
              looksHeroSized(width: width, height: height, descriptor: descriptor, url: lowercasedURL) else {
            return nil
        }

        return normalizedURL
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

    private func containsBlockedHeroHint(in text: String) -> Bool {
        blockedHeroImageHints.contains { text.contains($0) }
    }

    private func isObviouslyTinyImage(width: Int?, height: Int?) -> Bool {
        if let width, width <= 4 {
            return true
        }

        if let height, height <= 4 {
            return true
        }

        if let width, let height {
            let (area, overflow) = width.multipliedReportingOverflow(by: height)
            if !overflow, area <= 20_000 {
                return true
            }
        }

        return false
    }

    private func looksHeroSized(width: Int?, height: Int?, descriptor: String, url: String) -> Bool {
        if let width, width >= 240 {
            return true
        }

        if let height, height >= 120 {
            return true
        }

        if positiveHeroImageHints.contains(where: descriptor.contains) {
            return true
        }

        return positiveHeroImageHints.contains(where: url.contains)
    }

    private func heroImageDisplayMode(
        width: Int?,
        height: Int?,
        descriptor: String,
        url: String
    ) -> NewsletterPreviewHeroImageDisplayMode? {
        guard let aspectRatio = aspectRatio(width: width, height: height) else {
            return .fill
        }

        let looksLikeBanner = bannerLikeHeroImageHints.contains(where: descriptor.contains)
            || bannerLikeHeroImageHints.contains(where: url.contains)
        let looksPromotional = promotionalHeroImageHints.contains(where: descriptor.contains)
            || promotionalHeroImageHints.contains(where: url.contains)

        if aspectRatio >= 4.0, looksLikeBanner || looksPromotional {
            return nil
        }

        if aspectRatio >= 2.8 {
            return .fit
        }

        if aspectRatio >= 2.3, looksLikeBanner {
            return .fit
        }

        return .fill
    }

    private func aspectRatio(width: Int?, height: Int?) -> Double? {
        guard let width, let height, width > 0, height > 0 else {
            return nil
        }

        return Double(width) / Double(height)
    }

    private func isRenderableRemoteImageURL(_ url: String) -> Bool {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowercased = trimmed.lowercased()
        guard !lowercased.isEmpty,
              !lowercased.hasPrefix("cid:"),
              !lowercased.hasPrefix("data:"),
              !lowercased.contains("about:blank"),
              let parsedURL = URL(string: trimmed),
              let scheme = parsedURL.scheme?.lowercased(),
              let host = parsedURL.host,
              !host.isEmpty else {
            return false
        }

        return scheme == "http" || scheme == "https"
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

    private func normalizedPreviewSummary(
        _ text: String?,
        excluding excluded: [String?],
        excludedValues: Set<String>
    ) -> String? {
        var normalized = trimmedPreviewBoundaryText(normalizedText(text))
        normalized = trimmingLeadingExcludedText(from: normalized, excluded: excluded)
        normalized = trimmingFooterContent(from: normalized)

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

    private func trimmingLeadingExcludedText(from text: String, excluded: [String?]) -> String {
        let candidates = excluded
            .compactMap { candidate -> String? in
                let normalized = normalizedText(candidate)
                guard normalized.count >= 4 else {
                    return nil
                }
                return normalized
            }
            .sorted { $0.count > $1.count }

        guard !candidates.isEmpty else {
            return text
        }

        var trimmed = text

        while true {
            let previousValue = trimmed

            for candidate in candidates {
                guard let range = trimmed.range(of: candidate, options: [.anchored, .caseInsensitive]) else {
                    continue
                }

                trimmed = trimmedPreviewBoundaryText(String(trimmed[range.upperBound...]))
                break
            }

            if trimmed == previousValue {
                return trimmed
            }
        }
    }

    private func trimmingFooterContent(from text: String) -> String {
        let footerStart = footerStopPatterns
            .compactMap { text.range(of: $0, options: [.caseInsensitive])?.lowerBound }
            .min()

        guard let footerStart else {
            return text
        }

        return trimmedPreviewBoundaryText(String(text[..<footerStart]))
    }

    private func trimmedPreviewBoundaryText(_ text: String) -> String {
        text
            .replacingOccurrences(of: "^[\\s\\-:;,.!?|>*]+", with: "", options: .regularExpression)
            .replacingOccurrences(of: "[\\s\\-:;,.!?|>*]+$", with: "", options: .regularExpression)
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

private struct HeroImageCandidate {
    let url: String
    let displayMode: NewsletterPreviewHeroImageDisplayMode
    let score: Int
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

private let positiveHeroImageHints = [
    "hero",
    "banner",
    "cover",
    "feature"
]

private let bannerLikeHeroImageHints = [
    "banner",
    "header",
    "masthead",
    "promo"
]

private let promotionalHeroImageHints = [
    "coupon",
    "deal",
    "discount",
    "membership",
    "offer",
    "promo",
    "sale",
    "shop"
]

private let blockedHeroImageHints = [
    "avatar",
    "beacon",
    "blank",
    "divider",
    "icon",
    "logo",
    "pixel",
    "social",
    "spacer",
    "tracking",
    "tracker",
    "transparent"
]
