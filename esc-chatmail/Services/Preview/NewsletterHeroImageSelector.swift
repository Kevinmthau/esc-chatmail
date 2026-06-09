import Foundation

/// A scored hero-image candidate for a newsletter preview card.
struct HeroImageCandidate {
    let url: String
    let displayMode: NewsletterPreviewHeroImageDisplayMode
    let score: Int
}

/// Picks the best hero image for a newsletter preview from the email's extracted
/// images, scoring each on size, shape, descriptor/URL hints, and the substance
/// of any following text, and rejecting tracking pixels, unsafe URLs, tiny
/// imagery, and logos/icons/spacers.
///
/// Extracted from `NewsletterPreviewBuilder` so the hero-image scoring lives in
/// one focused, independently testable unit. The hero-hint lists move here since
/// nothing else references them, and the URL sanitizer and tracking remover are
/// owned outright (stateless). The shared line preparation (`previewLines`), the
/// `shouldSkipLine` predicate, and the `PreviewLineProcessor` (footer detection)
/// are injected so the selector carries no other builder state.
struct NewsletterHeroImageSelector {
    private let lineProcessor: PreviewLineProcessor
    private let previewLines: (String) -> [String]
    private let shouldSkipLine: (String) -> Bool
    private let urlSanitizer = HTMLURLSanitizer()
    private let trackingRemover = HTMLTrackingRemover()

    init(
        lineProcessor: PreviewLineProcessor,
        previewLines: @escaping (String) -> [String],
        shouldSkipLine: @escaping (String) -> Bool
    ) {
        self.lineProcessor = lineProcessor
        self.previewLines = previewLines
        self.shouldSkipLine = shouldSkipLine
    }

    func bestCandidate(from images: [EmailPreviewImage]) -> HeroImageCandidate? {
        var bestCandidate: HeroImageCandidate?

        for image in images.prefix(8) {
            let width = image.width
            let height = image.height
            let descriptor = image.descriptor
            guard let safeSource = safeHeroImageURL(
                from: image.sourceURL,
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

            var score = 30 - (image.index * 3)

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

            score += imageContextScore(fromFollowingText: image.followingText)

            if let width, width <= 80 {
                score -= 15
            }

            if let height, height <= 80 {
                score -= 15
            }

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

    private func imageContextScore(fromPlainText plainText: String) -> Int {
        guard !plainText.isEmpty else {
            return 0
        }

        let lines = previewLines(plainText)
        var score = 0

        if lines.contains(where: isSubstantiveImageFollowupLine) {
            score += 14
        }

        if lines.allSatisfy(isNavigationLikeImageFollowupLine),
           lines.contains(where: isNavigationLikeImageFollowupLine) {
            score -= 14
        }

        return score
    }

    private func imageContextScore(fromFollowingText followingText: String) -> Int {
        imageContextScore(fromPlainText: PreviewTextUtilities.normalizedText(followingText))
    }

    private func isSubstantiveImageFollowupLine(_ line: String) -> Bool {
        if shouldSkipLine(line) || lineProcessor.shouldStopAtFooter(line) || isNavigationLikeImageFollowupLine(line) {
            return false
        }

        if line.count >= 60 {
            return true
        }

        return line.count >= 34 && line.range(of: "[.!?]$", options: .regularExpression) != nil
    }

    private func isNavigationLikeImageFollowupLine(_ line: String) -> Bool {
        let lowercased = line.lowercased()

        if lowercased.contains("shop") && lowercased.contains("events") {
            return true
        }

        if lowercased.contains("|") {
            let segments = lowercased
                .split(separator: "|")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }

            if segments.count >= 2,
               segments.allSatisfy({ segment in
                   segment.count <= 18 && segment.split(separator: " ").count <= 3
               }) {
                return true
            }
        }

        return false
    }

    private func safeHeroImageURL(
        from rawURL: String,
        descriptor: String,
        width: Int?,
        height: Int?
    ) -> String? {
        let normalizedURL = PreviewTextUtilities.normalizedText(rawURL)
        let lowercasedURL = normalizedURL.lowercased()

        guard PreviewTextUtilities.isRenderableRemoteImageURL(normalizedURL),
              urlSanitizer.isURLSafe(normalizedURL),
              !trackingRemover.isTrackingLikeImageURL(normalizedURL),
              !containsBlockedHeroHint(in: descriptor),
              !containsBlockedHeroHint(in: lowercasedURL),
              !isObviouslyTinyImage(width: width, height: height),
              looksHeroSized(width: width, height: height, descriptor: descriptor, url: lowercasedURL) else {
            return nil
        }

        return EmailPreviewRemoteImageURL.normalizedForNativePreview(normalizedURL)
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
        guard let aspectRatio = PreviewTextUtilities.aspectRatio(width: width, height: height) else {
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
}

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
