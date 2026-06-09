import Foundation

/// A scored candidate image for a transactional preview card.
struct TransactionalImageCandidate {
    let url: String
    let style: TransactionalPreviewImageStyle
    let score: Int
}

/// Picks the best avatar/card image for a transactional preview from the email's
/// extracted images, scoring each on shape, size, and URL/descriptor hints and
/// rejecting tracking pixels, unsafe URLs, and promotional/blocked imagery.
///
/// Extracted from `TransactionalPreviewBuilder` so the image-selection scoring
/// lives in one focused, independently testable unit. The promotional/blocked
/// hint lists (shared with the builder's line filtering) are injected; the URL
/// sanitizer and tracking remover are owned outright since they are stateless.
struct TransactionalImageSelector {
    private let urlSanitizer = HTMLURLSanitizer()
    private let trackingRemover = HTMLTrackingRemover()
    private let promotionalPatterns: [String]
    private let blockedImageHints: [String]

    init(promotionalPatterns: [String], blockedImageHints: [String]) {
        self.promotionalPatterns = promotionalPatterns
        self.blockedImageHints = blockedImageHints
    }

    func bestCandidate(from images: [EmailPreviewImage]) -> TransactionalImageCandidate? {
        var bestCandidate: TransactionalImageCandidate?

        for image in images.prefix(12) {
            let width = image.width
            let height = image.height
            let descriptor = image.descriptor

            guard let safeURL = safeImageURL(
                from: image.sourceURL,
                descriptor: descriptor,
                width: width,
                height: height
            ) else {
                continue
            }

            let lowercasedURL = safeURL.lowercased()
            let aspectRatio = PreviewTextUtilities.aspectRatio(width: width, height: height)
            let looksSquare = aspectRatio.map { $0 >= 0.8 && $0 <= 1.25 } ?? false
            let impliesAvatar =
                descriptor.contains("profile") ||
                descriptor.contains("avatar") ||
                lowercasedURL.contains("pics-v") ||
                lowercasedURL.contains("profile") ||
                lowercasedURL.contains("avatar")
            let isAvatarLike =
                (looksSquare &&
                 min(width ?? 0, height ?? 0) >= 40 &&
                 max(width ?? 0, height ?? 0) <= 160) ||
                (impliesAvatar &&
                 width.map { $0 > 36 } != false &&
                 height.map { $0 > 36 } != false)

            var score = 0

            if isAvatarLike {
                score += 28
            }

            if descriptor.contains("profile") || descriptor.contains("avatar") {
                score += 22
            }

            if descriptor.contains(" image") {
                score += 14
            }

            if lowercasedURL.contains("pics") || lowercasedURL.contains("profile") || lowercasedURL.contains("avatar") {
                score += 16
            }

            if let aspectRatio, aspectRatio > 1.8 {
                score -= 26
            }

            if descriptor.contains("logo") || descriptor.contains("wordmark") {
                score -= 20
            }

            if let width, width < 36 {
                score -= 16
            }

            if let height, height < 36 {
                score -= 16
            }

            let style: TransactionalPreviewImageStyle
            if isAvatarLike || impliesAvatar {
                style = .avatar
            } else if looksSquare {
                style = .card
                score += 6
            } else {
                continue
            }

            guard score >= 20 else {
                continue
            }

            let candidate = TransactionalImageCandidate(url: safeURL, style: style, score: score)
            if bestCandidate == nil || score > (bestCandidate?.score ?? Int.min) {
                bestCandidate = candidate
            }
        }

        return bestCandidate
    }

    private func safeImageURL(from rawURL: String, descriptor: String, width: Int?, height: Int?) -> String? {
        let normalizedURL = PreviewTextUtilities.normalizedText(rawURL)
        let lowercasedURL = normalizedURL.lowercased()

        guard PreviewTextUtilities.isRenderableRemoteImageURL(normalizedURL),
              urlSanitizer.isURLSafe(normalizedURL),
              !trackingRemover.isTrackingLikeImageURL(normalizedURL),
              !promotionalPatterns.contains(where: descriptor.contains),
              !promotionalPatterns.contains(where: lowercasedURL.contains),
              !blockedImageHints.contains(where: descriptor.contains),
              !blockedImageHints.contains(where: lowercasedURL.contains) else {
            return nil
        }

        if let width, let height, (width <= 8 || height <= 8) {
            return nil
        }

        return EmailPreviewRemoteImageURL.normalizedForNativePreview(normalizedURL)
    }
}
