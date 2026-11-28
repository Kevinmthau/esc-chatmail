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

    /// The frame a photo bubble's preview is decoded to cover (`ThumbnailDecodeSize`), chosen
    /// once, when the bubble loads it: nothing reloads the preview when the frame or the scale
    /// changes afterwards, and a reload would flash the placeholder
    /// (`AttachmentThumbnailLoader.prepare(for:)` clears the image when the request changes).
    ///
    /// So it is the largest frame the bubble can take, not the one it has. Where the style has a
    /// fixed width (`widestMaxWidth`, the Mac's 400 points), the frame at that width, never at a
    /// narrow column's current one: a window made wider afterwards widens the image up to it.
    /// And at the largest scale the bubble can be drawn at (`largestDisplayScale`, on the Mac
    /// `PlatformScreen.scale`, the highest among the connected screens), never only its window's
    /// current one: a window dragged from a 1x display onto a Retina one doubles it. Measured
    /// on neither: drawn from a bitmap decoded for the narrow 1x frame, the image would have been
    /// upscaled up to three times (architecture review 2026-11, caching-memory#1's review). On
    /// iOS both are the frame and the scale it has, and a rotation's change of width is within the
    /// size's 128-pixel rounding.
    static func previewDecodeSize(
        pixelWidth: CGFloat,
        pixelHeight: CGFloat,
        maxWidth: CGFloat,
        widestMaxWidth: CGFloat?,
        displayScale: CGFloat,
        largestDisplayScale: CGFloat,
        presentation: InlineImagePresentationPolicy
    ) -> ThumbnailDecodeSize? {
        let frame = size(
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight,
            maxWidth: max(maxWidth, widestMaxWidth ?? 0),
            displayScale: displayScale,
            presentation: presentation
        )
        return ThumbnailDecodeSize(points: frame, displayScale: max(displayScale, largestDisplayScale))
    }
}
