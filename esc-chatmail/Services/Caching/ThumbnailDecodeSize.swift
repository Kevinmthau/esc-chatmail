import CoreGraphics
import Foundation

/// The frame, in pixels, a view draws an attachment's stored preview into, which
/// `AttachmentCacheActor.loadThumbnail(…decodeSize:)` decodes the preview to cover.
///
/// A preview is up to `ImageProcessor.maxThumbnailDimension` (1,600 px) on its longer side, and
/// an image within that is its own preview, so a single photo's bubble decoded a bitmap of up to
/// about 7.7 MB (1,600 x 1,200 x 4) to draw it at 840 px or less, and a PDF card one of up to
/// 1.9 MB to draw it 60 points wide (architecture review 2026-11, caching-memory#1). The view now
/// names the frame it reserved, in points, and its display's scale, and the preview is decoded
/// to the least size that covers that frame (`longerSide(forSourceOf:)`). Covering, not fitting:
/// the PDF card and a draft's thumbnail draw aspect-fill, where fitting would leave a page that is
/// wider than its frame soft, and for a view that draws to fit, covering is never less.
///
/// Each side is rounded up to a multiple of `pixelStep`, and the size is part of the cache key, so
/// a frame that moves by a point keeps hitting the same entry; rounding up never draws a preview
/// softer than its frame.
struct ThumbnailDecodeSize: Hashable, Sendable {
    /// The granularity of each side, in pixels.
    static let pixelStep = 128

    let pixelWidth: Int
    let pixelHeight: Int

    /// The frame `pointSize` on a display of `displayScale`, each side rounded up to a multiple of
    /// `pixelStep`; nil where either side or the scale is not a positive, finite size, and the
    /// preview is then decoded at its own size.
    init?(points pointSize: CGSize, displayScale: CGFloat) {
        guard let width = Self.roundedUpPixels(pointSize.width * displayScale),
              let height = Self.roundedUpPixels(pointSize.height * displayScale) else {
            return nil
        }
        pixelWidth = width
        pixelHeight = height
    }

    /// The longer side, in pixels, to decode a source of `sourcePixelSize` to so that it covers
    /// this frame: scaled by the larger of the two ratios, rounded up, and never more than the
    /// source's own longer side.
    func longerSide(forSourceOf sourcePixelSize: CGSize) -> CGFloat {
        let sourceLongerSide = max(sourcePixelSize.width, sourcePixelSize.height)
        guard sourcePixelSize.width > 0, sourcePixelSize.height > 0 else { return sourceLongerSide }
        // Multiplied before it is divided, so a frame side that is the source's scaled exactly
        // (1,600 x 896 / 1,600) is that number, not a hair over it that rounds up a pixel.
        let covering = max(
            sourceLongerSide * CGFloat(pixelWidth) / sourcePixelSize.width,
            sourceLongerSide * CGFloat(pixelHeight) / sourcePixelSize.height
        )
        return min(covering.rounded(.up), sourceLongerSide)
    }

    /// What this size adds to a cache key.
    var cacheKeyComponent: String {
        "|px\(pixelWidth)x\(pixelHeight)"
    }

    private static func roundedUpPixels(_ value: CGFloat) -> Int? {
        guard value.isFinite, value > 0, value <= CGFloat(Int32.max) else { return nil }
        let pixels = Int(value.rounded(.up))
        return ((pixels + pixelStep - 1) / pixelStep) * pixelStep
    }
}
