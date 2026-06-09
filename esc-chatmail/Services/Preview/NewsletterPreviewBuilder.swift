import Foundation

struct NewsletterPreviewBuilder {
    private let imageExtractor = EmailPreviewImageExtractor()
    private let lineProcessor = PreviewLineProcessor(
        config: PreviewLineProcessorConfig(
            footerStopPatterns: footerStopPatterns,
            truncationTrailingMinDistance: 32
        )
    )
    private static let leadingPreviewURLRegex = try? NSRegularExpression(
        pattern: #"^\s*[\(\[\{<]?\s*((?:https?://|www\.)[^\s\)\]\}>]+)(?:\s*[\)\]\}>])?\s*"#,
        options: [.caseInsensitive]
    )

    func buildPreview(
        canonicalHTML: String,
        bodyText: String?,
        cleanedSnippet: String? = nil,
        senderName: String? = nil,
        senderEmail: String?,
        subject: String? = nil
    ) -> NewsletterPreviewModel? {
        let extractedContent = EmailPreviewContentExtractor.extract(
            canonicalHTML: canonicalHTML,
            bodyText: bodyText,
            imageExtractor: imageExtractor
        )

        return buildPreview(
            canonicalHTML: canonicalHTML,
            plainText: extractedContent.plainText,
            extractedText: extractedContent.htmlText,
            extractedImages: extractedContent.images,
            htmlSummary: extractedContent.htmlSummary,
            cleanedSnippet: cleanedSnippet,
            senderName: senderName,
            senderEmail: senderEmail,
            subject: subject
        )
    }

    func buildPreview(
        source: EmailPreviewSource,
        cleanedSnippet: String? = nil,
        senderName: String? = nil,
        senderEmail: String?,
        subject: String? = nil
    ) -> NewsletterPreviewModel? {
        guard let canonicalHTML = source.canonicalHTML else {
            return nil
        }

        return buildPreview(
            canonicalHTML: canonicalHTML,
            plainText: source.plainText,
            extractedText: source.extractedText,
            extractedImages: source.extractedImages,
            htmlSummary: source.htmlSummary,
            cleanedSnippet: cleanedSnippet,
            senderName: senderName,
            senderEmail: senderEmail,
            subject: subject
        )
    }

    private func buildPreview(
        canonicalHTML: String,
        plainText: String?,
        extractedText: String?,
        extractedImages: [EmailPreviewImage],
        htmlSummary: EmailPreviewHTMLSummary,
        cleanedSnippet: String?,
        senderName: String?,
        senderEmail: String?,
        subject: String?
    ) -> NewsletterPreviewModel? {
        let sourceDomain = PreviewTextUtilities.normalizedSourceDomain(from: senderEmail)
        let sourceLabelResolver = NewsletterSourceLabelResolver(lineProcessor: lineProcessor)
        let sourceLabel = sourceLabelResolver.sourceLabel(
            senderName: senderName,
            senderEmail: senderEmail,
            sourceDomain: sourceDomain
        )
        let title = resolvedTitle(from: htmlSummary, subject: subject)
        let lineAnalyzer = NewsletterLineAnalyzer(
            lineProcessor: lineProcessor,
            shouldSkipLine: shouldSkipLine,
            lineLooksLikePreviewNoise: lineLooksLikePreviewNoise,
            trimmingLeadingPreviewURLNoise: trimmingLeadingPreviewURLNoise
        )
        let lines = lineAnalyzer.cleanedLines(
            plainText: plainText,
            canonicalHTML: canonicalHTML,
            extractedText: extractedText
        )
        let subtitle = resolvedSubtitle(from: lines, excluding: [title, subject, sourceLabel, sourceDomain])
        let snippet = resolvedSnippet(
            preferredSnippet: cleanedSnippet,
            from: lines,
            excluding: [title, subtitle, subject, sourceLabel, sourceDomain]
        )
        let heroImageSelector = NewsletterHeroImageSelector(
            lineProcessor: lineProcessor,
            previewLines: lineAnalyzer.previewLines,
            shouldSkipLine: shouldSkipLine
        )
        let heroImage = heroImageSelector.bestCandidate(from: extractedImages)
        let heroImageURL = heroImage?.url

        guard title != nil || subtitle != nil || snippet != nil || heroImageURL != nil else {
            return nil
        }

        let normalizedSubject = PreviewTextUtilities.normalizedText(subject)
        let fallbackSubject = normalizedSubject.isEmpty ? nil : normalizedSubject
        let resolvedTitle = title ?? fallbackSubject ?? sourceLabel ?? "Newsletter"
        let resolvedSnippet = snippet ?? subtitle ?? sourceDomain ?? "Open the full email to view the complete message."

        return NewsletterPreviewModel(
            title: resolvedTitle,
            subtitle: subtitle,
            snippet: lineProcessor.truncate(resolvedSnippet, limit: 220),
            heroImageURL: heroImageURL,
            heroImageDisplayMode: heroImage?.displayMode ?? .fill,
            sourceLabel: sourceLabel,
            sourceDomain: sourceDomain
        )
    }

    private func resolvedTitle(from htmlSummary: EmailPreviewHTMLSummary, subject: String?) -> String? {
        let candidates = [
            htmlSummary.h1Text,
            htmlSummary.h2Text,
            newsletterPreheaderText(htmlSummary.preheaderText),
            htmlSummary.titleText,
            PreviewTextUtilities.normalizedText(subject)
        ]

        for candidate in candidates {
            guard let candidate, isMeaningfulTitle(candidate) else {
                continue
            }
            return lineProcessor.truncate(candidate, limit: 120)
        }

        return nil
    }

    private func newsletterPreheaderText(_ text: String?) -> String? {
        guard let text = PreviewTextUtilities.normalizedPreviewText(text),
              !shouldSkipLine(text),
              !lineProcessor.shouldStopAtFooter(text) else {
            return nil
        }

        return text
    }

    private func resolvedSubtitle(from lines: [String], excluding excluded: [String?]) -> String? {
        let excludedValues = PreviewTextUtilities.normalizedSet(from: excluded)

        for line in lines {
            let comparable = PreviewTextUtilities.normalizedComparableText(line)
            guard !excludedValues.contains(comparable),
                  !TextProcessing.isListItem(line),
                  line.count >= 18,
                  line.count <= 55 else {
                continue
            }

            return lineProcessor.truncate(line, limit: 110)
        }

        return nil
    }

    private func resolvedSnippet(
        preferredSnippet: String?,
        from lines: [String],
        excluding excluded: [String?]
    ) -> String? {
        let excludedValues = PreviewTextUtilities.normalizedSet(from: excluded)

        if let preferredSnippet = normalizedPreviewSummary(
            preferredSnippet,
            excluding: excluded,
            excludedValues: excludedValues
        ) {
            return lineProcessor.truncate(preferredSnippet, limit: 190)
        }

        var collected: [String] = []

        for line in lines {
            let comparable = PreviewTextUtilities.normalizedComparableText(line)
            guard !excludedValues.contains(comparable) else {
                continue
            }

            if collected.isEmpty && line.count < 30 {
                continue
            }

            collected.append(line)
            let joined = collected.joined(separator: " ")
            if joined.count >= 170 {
                return lineProcessor.truncate(joined, limit: 190)
            }
        }

        let joined = collected.joined(separator: " ")
        return joined.isEmpty ? nil : lineProcessor.truncate(joined, limit: 190)
    }

    private func normalizedPreviewSummary(
        _ text: String?,
        excluding excluded: [String?],
        excludedValues: Set<String>
    ) -> String? {
        var normalized = trimmedPreviewBoundaryText(PreviewTextUtilities.normalizedText(text))
        normalized = trimmingLeadingPreviewURLNoise(from: normalized, requiringTrackingURL: true)
        normalized = trimmingLeadingExcludedText(from: normalized, excluded: excluded)
        normalized = trimmingFooterContent(from: normalized)

        guard !normalized.isEmpty,
              normalized.count >= 24,
              !lineLooksLikePreviewNoise(normalized),
              !looksLikeShortTitleCluster(normalized),
              !shouldSkipLine(normalized),
              !lineProcessor.shouldStopAtFooter(normalized) else {
            return nil
        }

        let comparable = PreviewTextUtilities.normalizedComparableText(normalized)
        guard !excludedValues.contains(comparable) else {
            return nil
        }

        return normalized
    }

    private func trimmingLeadingExcludedText(from text: String, excluded: [String?]) -> String {
        let candidates = excluded
            .compactMap { candidate -> String? in
                let normalized = PreviewTextUtilities.normalizedText(candidate)
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

    private func shouldSkipLine(_ line: String) -> Bool {
        let lowercased = line.lowercased()

        if lowercased.count < 4 {
            return true
        }

        if lineLooksLikePreviewNoise(line) {
            return true
        }

        if startsWithPreviewURLNoise(line) {
            return true
        }

        return ignoredLinePatterns.contains { lowercased.contains($0) }
    }

    private func lineLooksLikePreviewNoise(_ line: String) -> Bool {
        let lowercased = line.lowercased()

        if startsWithPreviewURLNoise(line) {
            return true
        }

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

    private func looksLikeShortTitleCluster(_ line: String) -> Bool {
        guard line.count <= 80 else {
            return false
        }

        let fragments = line
            .split { ".!?".contains($0) }
            .map { PreviewTextUtilities.normalizedText(String($0)) }
            .filter { !$0.isEmpty }

        guard fragments.count >= 2 else {
            return false
        }

        return fragments.allSatisfy { fragment in
            let tokens = previewWordTokens(in: fragment)
            guard !tokens.isEmpty, tokens.count <= 3 else {
                return false
            }

            return fragment.split(separator: " ").allSatisfy { word in
                guard let first = word.first, first.isLetter else {
                    return true
                }
                return first.isUppercase
            }
        }
    }

    private func startsWithPreviewURLNoise(_ line: String) -> Bool {
        let withoutLeadingWrapper = line
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "([{<"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        return withoutLeadingWrapper.hasPrefix("http://") ||
            withoutLeadingWrapper.hasPrefix("https://") ||
            withoutLeadingWrapper.hasPrefix("www.")
    }

    private func trimmingLeadingPreviewURLNoise(from line: String, requiringTrackingURL: Bool = false) -> String {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let match = leadingPreviewURLMatch(in: trimmed) else {
            return line
        }

        let trimmedText = trimmedPreviewBoundaryText(String(trimmed[match.range.upperBound...]))
            .replacingOccurrences(of: #"^[\)\]\}]+\s*"#, with: "", options: .regularExpression)

        guard !requiringTrackingURL ||
                isTrackingLikePreviewURL(match.url) ||
                isUTMTrackingLikePreviewURL(match.url) && postURLTextLooksLikePreviewTeaser(trimmedText) else {
            return line
        }

        return trimmedText
    }

    private func leadingPreviewURLMatch(in line: String) -> (range: Range<String.Index>, url: String)? {
        guard let match = Self.leadingPreviewURLRegex?.firstMatch(
            in: line,
            range: NSRange(line.startIndex..., in: line)
        ),
              let range = Range(match.range, in: line),
              let urlRange = Range(match.range(at: 1), in: line) else {
            return nil
        }

        return (range, String(line[urlRange]))
    }

    private func isTrackingLikePreviewURL(_ rawURL: String) -> Bool {
        var normalized = rawURL
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        if normalized.hasPrefix("www.") {
            normalized = "https://\(normalized)"
        }

        guard let components = URLComponents(string: normalized) else {
            return false
        }

        let trackingTokens: Set<String> = [
            "click",
            "clicks",
            "link",
            "links",
            "redirect",
            "redir",
            "track",
            "tracking",
            "trk"
        ]
        let hostSegments = components.host?
            .split(separator: ".")
            .map(String.init) ?? []
        if hostSegments.contains(where: trackingTokens.contains) {
            return true
        }

        let pathSegments = components.path
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)

        return pathSegments.contains(where: trackingTokens.contains)
    }

    private func isUTMTrackingLikePreviewURL(_ rawURL: String) -> Bool {
        var normalized = rawURL
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        if normalized.hasPrefix("www.") {
            normalized = "https://\(normalized)"
        }

        guard let components = URLComponents(string: normalized) else {
            return false
        }

        return components.queryItems?.contains { $0.name.lowercased().hasPrefix("utm_") } == true
    }

    private func postURLTextLooksLikePreviewTeaser(_ text: String) -> Bool {
        let normalized = PreviewTextUtilities.normalizedText(text)
        guard normalized.count >= 24,
              !shouldSkipLine(normalized),
              !lineProcessor.shouldStopAtFooter(normalized),
              !looksLikeNavigationLabelRun(normalized) else {
            return false
        }

        let tokens = previewWordTokens(in: normalized)
        let connectorCount = tokens.filter { teaserConnectorTokens.contains($0) }.count
        return normalized.count >= 70 ||
            normalized.range(of: "[.!?,;:]", options: .regularExpression) != nil ||
            normalized.lowercased().contains("just landed") ||
            connectorCount >= 2
    }

    private func looksLikeNavigationLabelRun(_ line: String) -> Bool {
        let tokens = previewWordTokens(in: line)
        guard tokens.count >= 4 else {
            return false
        }

        let navigationTokenCount = tokens.filter { navigationSnippetTokens.contains($0) }.count
        if tokens.first == "shop",
           navigationTokenCount >= 3,
           navigationTokenCount * 2 >= tokens.count {
            return true
        }

        return navigationTokenCount >= 4 && navigationTokenCount * 2 >= tokens.count
    }

    private func previewWordTokens(in text: String) -> [String] {
        text.lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
    }

    private func isMeaningfulTitle(_ title: String) -> Bool {
        let normalized = PreviewTextUtilities.normalizedText(title)
        guard normalized.count >= 12 else {
            return false
        }

        let lowercased = normalized.lowercased()
        guard !ignoredTitlePatterns.contains(where: { lowercased.contains($0) }) else {
            return false
        }

        return true
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

private let navigationSnippetTokens: Set<String> = [
    "accessories",
    "arrivals",
    "bags",
    "beauty",
    "clearance",
    "clothing",
    "dresses",
    "gift",
    "gifts",
    "home",
    "jewelry",
    "kids",
    "men",
    "new",
    "outlet",
    "sale",
    "shop",
    "shoes",
    "stores",
    "women"
]

private let teaserConnectorTokens: Set<String> = [
    "a",
    "an",
    "and",
    "are",
    "for",
    "from",
    "in",
    "is",
    "of",
    "on",
    "our",
    "the",
    "this",
    "to",
    "with",
    "your"
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
