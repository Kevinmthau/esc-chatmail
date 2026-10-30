import Foundation

/// Reserves chat attachment geometry from metadata, before the thumbnail is decoded.
/// The decoded image never participates in sizing, including when dimensions are unknown.
enum ImageAttachmentLayout {
    static func size(
        pixelWidth: CGFloat,
        pixelHeight: CGFloat,
        maxWidth: CGFloat,
        displayScale: CGFloat,
        presentation: InlineImagePresentationPolicy
    ) -> CGSize {
        let widthLimit = maxWidth.isFinite && maxWidth > 0 ? maxWidth : 200
        guard pixelWidth.isFinite, pixelHeight.isFinite,
              pixelWidth > 0, pixelHeight > 0 else {
            let width = min(200, widthLimit)
            return CGSize(width: width, height: width * 0.75)
        }

        if presentation == .compact {
            let padding = min(16, widthLimit)
            let scale = displayScale.isFinite && displayScale > 0 ? displayScale : 1
            let imageSize = InlineImagePresentationPolicy.fittedSize(
                pixelWidth: pixelWidth,
                pixelHeight: pixelHeight,
                maxWidth: widthLimit - padding,
                displayScale: scale
            )
            return CGSize(width: imageSize.width + padding, height: imageSize.height + padding)
        }

        // A very tall scan should not create a multi-screen chat row. The full
        // attachment remains available in Quick Look; fit the entire thumbnail here.
        let scale = min(widthLimit / pixelWidth, 420 / pixelHeight)
        return CGSize(width: pixelWidth * scale, height: pixelHeight * scale)
    }
}
