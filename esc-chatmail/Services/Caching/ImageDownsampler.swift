import UIKit
import ImageIO

/// Data-based analog of AttachmentCacheActor's URL downsampler: decodes image
/// bytes into a UIImage capped at a maximum pixel dimension without first
/// materializing the full-resolution bitmap (CGImageSource thumbnailing).
enum ImageDownsampler {

    /// Decoded-bitmap cap for cached remote images. Chosen to sit at or above
    /// the widest current iPhone full-width render (Pro Max 3×), so no
    /// consumer loses visible quality — the disk image cache's consumer audit
    /// found nothing rendering beyond card width — while multi-megapixel
    /// photos stop decoding to 30+ MB bitmaps. A constant rather than a live
    /// UIScreen read: callers include non-main actors.
    static let defaultMaxPixelDimension: CGFloat = 1440

    /// Decodes `data` into a UIImage whose larger pixel dimension is at most
    /// `maxPixelDimension`. Images already within the cap decode directly
    /// (dimension gate); undecodable data returns nil.
    static func decode(data: Data, maxPixelDimension: CGFloat = defaultMaxPixelDimension) -> UIImage? {
        guard !data.isEmpty, maxPixelDimension > 0, maxPixelDimension.isFinite else {
            return nil
        }

        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) else {
            return nil
        }

        // Dimension gate (same pattern as AttachmentCacheActor): small images
        // decode directly instead of paying the thumbnail path.
        if let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
           let width = properties[kCGImagePropertyPixelWidth] as? CGFloat,
           let height = properties[kCGImagePropertyPixelHeight] as? CGFloat,
           width <= maxPixelDimension, height <= maxPixelDimension {
            return UIImage(data: data)
        }

        let thumbnailOptions = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelDimension
        ] as CFDictionary

        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions) else {
            // Prefer a full-resolution decode over dropping the image.
            return UIImage(data: data)
        }
        return UIImage(cgImage: cgImage)
    }
}
