import Foundation
import ImageIO
#if canImport(UIKit)
import UIKit
#endif

/// Data-based analog of AttachmentCacheActor's URL downsampler: decodes image
/// bytes into a PlatformImage capped at a maximum pixel dimension without first
/// materializing the full-resolution bitmap (CGImageSource thumbnailing).
///
/// The bytes are a sender's: a remote image a mail's HTML names, fetched by
/// `RemoteImageFetcher` or `HTMLRemoteImageAttachmentFallback`, or one the disk
/// image cache kept from an earlier fetch. So the size the header declares is
/// read first, and an image past the source-pixel budget is refused before any
/// of it is decoded (architecture review 2026-11, `security-privacy#1`): a PNG
/// of a few hundred bytes can declare 30,000 x 30,000, which decodes to 3.6 GB.
/// Every decode of fetched image bytes goes through `decode`, never
/// `PlatformImage(data:)`, which has no such check.
enum ImageDownsampler {

    /// Decoded-bitmap cap for cached remote images. Chosen to sit at or above
    /// the widest current iPhone full-width render (Pro Max 3×), so no
    /// consumer loses visible quality — the disk image cache's consumer audit
    /// found nothing rendering beyond card width — while multi-megapixel
    /// photos stop decoding to 30+ MB bitmaps. A constant rather than a live
    /// UIScreen read: callers include non-main actors.
    static let defaultMaxPixelDimension: CGFloat = 1440

    /// Decodes `data` into a PlatformImage whose larger pixel dimension is at most
    /// `maxPixelDimension`. Images already within the cap decode directly
    /// (dimension gate); undecodable data returns nil.
    ///
    /// Returns nil, decoding nothing, where the header declares more than
    /// `maxSourcePixelCount` pixels, and where it declares no size at all: an
    /// image whose size cannot be read cannot be shown to be within the budget.
    /// The budget is the attachment previews' (`ImageProcessor`), one number
    /// for every image the app decodes for a sender.
    static func decode(
        data: Data,
        maxPixelDimension: CGFloat = defaultMaxPixelDimension,
        maxSourcePixelCount: CGFloat = ImageProcessor.maxThumbnailSourcePixelCount
    ) -> PlatformImage? {
        guard !data.isEmpty, maxPixelDimension > 0, maxPixelDimension.isFinite else {
            return nil
        }

        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions),
              let sourcePixelSize = ImageProcessor.sourcePixelSize(of: source),
              ImageProcessor.isWithinDecodeBudget(
                  sourcePixelSize,
                  maxSourcePixelCount: maxSourcePixelCount
              ) else {
            return nil
        }

        // Dimension gate (same pattern as AttachmentCacheActor): small images
        // decode directly instead of paying the thumbnail path.
        if sourcePixelSize.width <= maxPixelDimension, sourcePixelSize.height <= maxPixelDimension {
            return PlatformImage(data: data)
        }

        let thumbnailOptions = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelDimension
        ] as CFDictionary

        // No full-resolution fallback. This image is past the cap, so decoding
        // it whole is the multi-megapixel bitmap the cap is there to prevent,
        // for an image ImageIO has just failed to read.
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions) else {
            return nil
        }
        return PlatformImage(cgImage: cgImage)
    }
}
