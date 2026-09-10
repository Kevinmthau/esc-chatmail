import Foundation

/// Presentation for surviving received inline images; this never decides
/// whether an attachment is a signature or changes full-email rendering.
enum InlineImagePresentationPolicy: Equatable {
    case standard
    case compact
    case collapsed

    static func resolve(
        attachment: some DisplayFilterableAttachment,
        isFromMe: Bool,
        isHTMLPreview: Bool,
        bodyContentIDs: Set<String>,
        hasLoadedAnalysis: Bool = true
    ) -> Self {
        guard !isFromMe, !isHTMLPreview, attachment.mimeType.hasPrefix("image/"),
              let contentID = EmailDocument.normalizedContentID(attachment.contentId),
              attachment.state != .failed else { return .standard }
        if attachment.state == .queued && (attachment.width == 0 || attachment.height == 0) {
            return .collapsed
        }
        guard hasLoadedAnalysis, !bodyContentIDs.contains(contentID), attachment.width > 0, attachment.height > 0,
              attachment.width <= 900, attachment.height <= 900 else {
            return .standard
        }
        return .compact
    }

    static func requiresExplicitRetry(attachment: some DisplayFilterableAttachment, isFromMe: Bool) -> Bool {
        !isFromMe && attachment.state == .failed && attachment.mimeType.hasPrefix("image/") &&
            EmailDocument.normalizedContentID(attachment.contentId) != nil &&
            (attachment.width == 0 || attachment.height == 0)
    }

    static func fittedSize(pixelWidth: CGFloat, pixelHeight: CGFloat, maxWidth: CGFloat, displayScale: CGFloat) -> CGSize {
        guard pixelWidth > 0, pixelHeight > 0 else { return .zero }
        let scale = max(displayScale, 1)
        let nativeWidth = pixelWidth / scale
        let nativeHeight = pixelHeight / scale
        let ratio = min(1, min(maxWidth / nativeWidth, 160 / nativeHeight))
        return CGSize(width: nativeWidth * ratio, height: nativeHeight * ratio)
    }
}
