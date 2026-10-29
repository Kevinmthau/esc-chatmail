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
    /// The end of a sentence: its punctuation and the space after it. A period
    /// inside a URL or a price has no space after it and ends nothing.
    private static let sentenceBoundaryRegex = try? NSRegularExpression(pattern: #"[.!?]+\s+"#)
    /// The longest footer lead-in `trimmingFooterContent` steps back over, per
    /// step, in UTF-16 units of the text the card shows (link labels, not
    /// targets). "Want to change how you receive these emails?" is 44.
    private static let maxFooterLeadInLength = 60

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
            isSkippedLinkTarget: isSkippedLinkTarget,
            isFooterLeadInQuestion: isFooterLeadInQuestion,
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
            shouldSkipLine: shouldSkipLine,
            brandNames: [senderName, sourceLabel]
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
        // A subtitle that stood in for the missing snippet is shown once, as the
        // snippet: the card renders both, so keeping it in both printed the same
        // line twice (an image-only campaign whose only text line is a caption).
        let displayedSubtitle = snippet == nil ? nil : subtitle

        return NewsletterPreviewModel(
            title: resolvedTitle,
            subtitle: displayedSubtitle,
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
        let linkLabels = previewSummaryLinkLabels(in: PreviewTextUtilities.normalizedText(text), excluding: excluded)
        var normalized = trimmingLeadingSummaryText(from: linkLabels.text, excluding: excluded)
        normalized = trimmingFooterContent(from: normalized)

        // The removed links' targets are judged with the snippet, as they were
        // before links were stripped: a stored snippet that links a social
        // profile is still rejected, so the card falls back to its lines rather
        // than showing a run of image-link labels.
        guard !normalized.isEmpty,
              normalized.count >= 24,
              !lineLooksLikePreviewNoise(normalized),
              !looksLikeShortTitleCluster(normalized),
              !shouldSkipLine(normalized),
              !linkLabels.targets.contains(where: isSkippedLinkTarget),
              !lineProcessor.shouldStopAtFooter(normalized) else {
            return nil
        }

        let comparable = PreviewTextUtilities.normalizedComparableText(normalized)
        guard !excludedValues.contains(comparable) else {
            return nil
        }

        return normalized
    }

    /// A stored snippet reduced to its Markdown link labels (`MarkdownLinkLabels`).
    /// `MessageProcessor` stores the plain-text part as the snippet when the
    /// HTML shows no text, which for an image-only campaign is all links. The
    /// snippet's leading trims and footer search run on it as stored first, in
    /// the same order as for a snippet without links, so a footer phrase in a
    /// link's target (`[Click here](…/unsubscribe)`) still ends the snippet,
    /// while one inside the leading subject or title does not. The footer's
    /// lead-in is then stepped back over on the label text, which is what the
    /// card shows: measured on the stored text, a link's URL earlier in the
    /// footer sentence ("You can [update your preferences](…) or
    /// [unsubscribe](…)") put a short lead-in over the cap and left it standing.
    /// Text with no links passes through unchanged.
    private func previewSummaryLinkLabels(in text: String, excluding excluded: [String?]) -> MarkdownLinkLabels.Result {
        guard MarkdownLinkLabels.containsLink(in: text) else {
            return MarkdownLinkLabels.Result(text: text, targets: [])
        }

        let stored = trimmingLeadingSummaryText(from: text, excluding: excluded)
        let footerStart = footerPatternStart(in: stored).map { footerStart in
            MarkdownLinkLabels.enclosingLinkStart(of: footerStart, in: MarkdownLinkLabels.linkRanges(in: stored)) ?? footerStart
        }
        // Cut with its trailing space, which the lead-in steps need to see the
        // boundary of the sentence the footer ended.
        let kept = footerStart.map { (stored as NSString).substring(to: $0) } ?? stored
        let linkLabels = MarkdownLinkLabels.replacingLinks(in: kept)
        // Labels keep their own padding (`[Manhattan Vintage ](…)`). Collapse
        // the runs without normalizing again, which would decode entities twice.
        var labels = RegexSanitizer.replace(in: linkLabels.text, regex: RegexSanitizer.whitespaceRunRegex, with: " ")
        if footerStart != nil {
            let leadInCut = footerCutLocation(in: labels, footerStart: (labels as NSString).length)
            labels = (labels as NSString).substring(to: leadInCut)
        }

        return MarkdownLinkLabels.Result(text: labels, targets: linkLabels.targets)
    }

    /// The trims a stored snippet's start gets before its footer is found: the
    /// boundary punctuation, a leading tracking URL, and the title, subject or
    /// source label it repeats.
    private func trimmingLeadingSummaryText(from text: String, excluding excluded: [String?]) -> String {
        var trimmed = trimmedPreviewBoundaryText(text)
        trimmed = trimmingLeadingPreviewURLNoise(from: trimmed, requiringTrackingURL: true)
        return trimmingLeadingExcludedText(from: trimmed, excluded: excluded)
    }

    /// A removed link's target judged for what a URL can say: a social network
    /// or an unsubscribe page (`ignoredLinePatterns`). Not `shouldSkipLine`,
    /// whose text-noise heuristics read `target=` or `{{…}}` in a query string
    /// as markup and would drop an ordinary content link.
    private func isSkippedLinkTarget(_ target: String) -> Bool {
        let lowercased = target.lowercased()
        return ignoredLinePatterns.contains { lowercased.contains($0) }
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
            // The candidate written as a link (`[Subject](url)`, Klaviyo's
            // headline): a stored snippet's trims run before its links are
            // stripped, so the match has to see through the link, or a footer
            // word inside the subject ("privacy policy") is found there first.
            let leadingLink = MarkdownLinkLabels.leadingLink(in: trimmed)

            for candidate in candidates {
                if let range = trimmed.range(of: candidate, options: [.anchored, .caseInsensitive]) {
                    trimmed = trimmedPreviewBoundaryText(String(trimmed[range.upperBound...]))
                    break
                }

                if let leadingLink,
                   trimmedPreviewBoundaryText(leadingLink.label).caseInsensitiveCompare(candidate) == .orderedSame {
                    trimmed = trimmedPreviewBoundaryText((trimmed as NSString).substring(from: NSMaxRange(leadingLink.range)))
                    break
                }
            }

            if trimmed == previousValue {
                return trimmed
            }
        }
    }

    /// `text` cut before its footer: at the first footer pattern, moved out of
    /// any Markdown link the pattern sits in (so no `[label](https://` is left
    /// behind), then back over a short lead-in: the rest of the pattern's own
    /// sentence and a question just before it ("You can update your
    /// preferences or unsubscribe.", "Don't want these emails? Unsubscribe.").
    /// Cutting at the pattern alone left such a lead-in standing as a stored
    /// snippet's whole text.
    ///
    /// The lead-in steps need a sentence boundary before the pattern and are
    /// capped at `maxFooterLeadInLength`: a stored snippet is often a plain-text
    /// body collapsed onto one line, whose line breaks no longer end sentences,
    /// and an unbounded step back would swallow real content.
    private func trimmingFooterContent(from text: String) -> String {
        guard let footerStart = footerPatternStart(in: text) else {
            return text
        }

        let cut = footerCutLocation(in: text, footerStart: footerStart)
        return trimmedPreviewBoundaryText((text as NSString).substring(to: cut))
    }

    /// The UTF-16 offset of the first footer pattern in `text`, if any.
    private func footerPatternStart(in text: String) -> Int? {
        footerStopPatterns
            .compactMap { text.range(of: $0, options: [.caseInsensitive])?.lowerBound }
            .min()
            .map { NSRange($0..<$0, in: text).location }
    }

    /// A line that is the footer's lead-in question ("No longer wish to receive
    /// our emails?"), whatever its wording, when the line after it is a footer
    /// stop: the line-path counterpart of `footerCutLocation`'s question step.
    private func isFooterLeadInQuestion(_ line: String) -> Bool {
        line.hasSuffix("?") && line.utf16.count <= Self.maxFooterLeadInLength
    }

    /// The UTF-16 offset `trimmingFooterContent` cuts at, given the footer
    /// pattern's. The link ranges are scanned once for the three offsets asked.
    private func footerCutLocation(in text: String, footerStart: Int) -> Int {
        let linkRanges = MarkdownLinkLabels.linkRanges(in: text)
        let outsideLink = { (location: Int) in MarkdownLinkLabels.enclosingLinkStart(of: location, in: linkRanges) ?? location }
        let patternCut = outsideLink(footerStart)
        let boundaries = Self.sentenceBoundaryRegex?.matches(
            in: text,
            range: NSRange(location: 0, length: patternCut)
        ) ?? []

        guard let lastBoundary = boundaries.last,
              patternCut - NSMaxRange(lastBoundary.range) <= Self.maxFooterLeadInLength else {
            return patternCut
        }

        let sentenceStart = NSMaxRange(lastBoundary.range)
        let questionStart = boundaries.dropLast().last.map { NSMaxRange($0.range) } ?? 0
        guard (text as NSString).substring(with: lastBoundary.range).contains("?"),
              lastBoundary.range.location - questionStart <= Self.maxFooterLeadInLength else {
            return outsideLink(sentenceStart)
        }

        return outsideLink(questionStart)
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
    // The lead-in ESPs put before their unsubscribe link ("No longer want to
    // receive these emails? Unsubscribe."), for when it sits on a line of its
    // own. Anchored on "these emails": "no longer wish to receive" alone also
    // matches ordinary copy ("…paper statements").
    "no longer want to receive these emails",
    "no longer wish to receive these emails",
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
