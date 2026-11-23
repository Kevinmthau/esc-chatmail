#if canImport(UIKit)
import UIKit
#endif
import CoreGraphics
import ImageIO
import PDFKit

struct ImageProcessor {
    static let maxThumbnailDimension: CGFloat = 1600
    static let maxFullSizeDimension: CGFloat = 4096
    static let jpegCompressionQuality: CGFloat = 0.85
    
    static func processImage(data: Data, maxDimension: CGFloat = maxFullSizeDimension) -> (processed: Data?, size: CGSize?) {
        // Validate data is not empty
        guard !data.isEmpty else {
            Log.debug("ImageProcessor: Empty data provided", category: .attachment)
            return (nil, nil)
        }

        // Try to create image from data
        guard let image = PlatformImage(data: data) else {
            Log.debug("ImageProcessor: Failed to create UIImage from data of size \(data.count)", category: .attachment)
            return (nil, nil)
        }

        // Validate image dimensions
        let size = image.pixelSize
        guard size.width > 0 && size.height > 0 else {
            Log.debug("ImageProcessor: Invalid image dimensions \(size)", category: .attachment)
            return (nil, nil)
        }

        let scale = min(maxDimension / max(size.width, size.height), 1.0)

        if scale >= 1.0 {
            return (data, size)
        }

        let newSize = CGSize(width: size.width * scale, height: size.height * scale)
        guard newSize.width > 0, newSize.height > 0,
              newSize.width.isFinite, newSize.height.isFinite else {
            Log.debug("ImageProcessor: Skipping image resize with invalid target size \(newSize)", category: .attachment)
            return (nil, nil)
        }

        guard let jpegData = PlatformImageRenderer.jpegData(
            drawing: image,
            pixelSize: newSize,
            compressionQuality: jpegCompressionQuality
        ) else {
            return (nil, nil)
        }
        return (jpegData, newSize)
    }
    
    /// The most pixels a source image may have for the app to decode it into a preview: 8,192
    /// squared, which takes in a 48-megapixel camera photo and a 63-megapixel panorama. The image
    /// is the sender's, and its header names its size before anything is decoded: a PNG of a few
    /// hundred bytes can declare 30,000 x 30,000, which decodes to 3.6 GB. Above this the
    /// attachment gets no preview, which is a valid final state (`AttachmentDownloader` stores a
    /// nil preview path and does not download again), and the original is still saved and opens.
    static let maxThumbnailSourcePixelCount: CGFloat = 8_192 * 8_192

    /// What `generateThumbnail` makes of an image of this many pixels, read from its header.
    enum ImageThumbnailPlan: Equatable {
        /// No preview: the size is unknown, empty, or past `maxThumbnailSourcePixelCount`.
        case refused
        /// Within `maxThumbnailDimension`: the original's own bytes are the preview.
        case original
        /// Past `maxThumbnailDimension`: a JPEG at that size, flattened onto white.
        case downsampled
    }

    static func imageThumbnailPlan(
        sourcePixelSize: CGSize,
        maxSourcePixelCount: CGFloat = maxThumbnailSourcePixelCount
    ) -> ImageThumbnailPlan {
        guard isWithinDecodeBudget(sourcePixelSize, maxSourcePixelCount: maxSourcePixelCount) else {
            return .refused
        }
        return max(sourcePixelSize.width, sourcePixelSize.height) > maxThumbnailDimension
            ? .downsampled
            : .original
    }

    /// Whether an image of this size may be decoded at all: both sides finite and positive, and
    /// no more than `maxSourcePixelCount` pixels.
    static func isWithinDecodeBudget(
        _ pixelSize: CGSize,
        maxSourcePixelCount: CGFloat = maxThumbnailSourcePixelCount
    ) -> Bool {
        guard pixelSize.width.isFinite, pixelSize.height.isFinite,
              pixelSize.width > 0, pixelSize.height > 0 else {
            return false
        }
        return pixelSize.width * pixelSize.height <= maxSourcePixelCount
    }

    /// The first image's size in pixels as its header states it, read without decoding it.
    /// Before any EXIF rotation, which a pixel count and a longest side do not depend on; never
    /// store it as the attachment's dimensions, which come from `getImageDimensions`.
    static func sourcePixelSize(of source: CGImageSource) -> CGSize? {
        guard CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue else {
            return nil
        }
        return CGSize(width: width, height: height)
    }

    static func generateThumbnail(from data: Data, mimeType: String) -> Data? {
        if mimeType.starts(with: "image/") {
            return generateImageThumbnail(from: data)
        } else if mimeType == "application/pdf" {
            return generatePDFThumbnail(from: data)
        }
        return nil
    }

    /// An image attachment's preview. The size is read from the header first, so an image past
    /// `maxSourcePixelCount` is refused before any of it is decoded. Within
    /// `maxThumbnailDimension` the preview is the original's bytes, unchanged; past it, ImageIO
    /// decodes straight to the preview's size (`CGImageSourceCreateThumbnailAtIndex`), never the
    /// whole image first, as drawing a `PlatformImage` did.
    static func generateImageThumbnail(
        from data: Data,
        maxSourcePixelCount: CGFloat = maxThumbnailSourcePixelCount
    ) -> Data? {
        guard !data.isEmpty,
              let source = CGImageSourceCreateWithData(
                  data as CFData,
                  [kCGImageSourceShouldCache: false] as CFDictionary
              ),
              let pixelSize = sourcePixelSize(of: source) else {
            return nil
        }

        switch imageThumbnailPlan(sourcePixelSize: pixelSize, maxSourcePixelCount: maxSourcePixelCount) {
        case .refused:
            Log.debug(
                "ImageProcessor: No preview for an image of \(Int(pixelSize.width)) x \(Int(pixelSize.height)) pixels",
                category: .attachment
            )
            return nil
        case .original:
            // As before: the bytes are kept only where the platform can make an image of them.
            guard PlatformImage(data: data) != nil else { return nil }
            return data
        case .downsampled:
            return downsampledImageThumbnail(from: source)
        }
    }

    /// A JPEG no longer than `maxThumbnailDimension` on either side, upright, and flattened onto
    /// white where the image is transparent, as `thumbnailFlattensTransparency` says.
    private static func downsampledImageThumbnail(from source: CGImageSource) -> Data? {
        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxThumbnailDimension
        ] as CFDictionary
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else {
            return nil
        }
        let pixelSize = CGSize(width: thumbnail.width, height: thumbnail.height)
        guard pixelSize.width > 0, pixelSize.height > 0 else { return nil }

        return PlatformImageRenderer.opaqueJPEGData(
            pixelSize: pixelSize,
            compressionQuality: jpegCompressionQuality
        ) { context in
            let rect = CGRect(origin: .zero, size: pixelSize)
            context.setFillColor(PlatformColor.white.cgColor)
            context.fill(rect)
            // The renderer's coordinates have y growing downward; a CGImage draws upright only
            // in Core Graphics' own, so flip back for the draw.
            context.translateBy(x: 0, y: pixelSize.height)
            context.scaleBy(x: 1, y: -1)
            context.draw(thumbnail, in: rect)
        }
    }
    
    /// Whether `generateThumbnail` flattened this image onto white where a transparent logo could
    /// have been lost. Over the size limit it re-encodes as JPEG; within it the bytes are unchanged.
    /// Answers from the attachment's stored metadata, so it needs no read of either file.
    static func thumbnailFlattensTransparency(
        pixelWidth: CGFloat,
        pixelHeight: CGFloat,
        mimeType: String
    ) -> Bool {
        let normalizedMimeType = mimeType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return max(pixelWidth, pixelHeight) > maxThumbnailDimension
            && logoMimeTypes.contains(normalizedMimeType)
    }

    /// The formats a transparent logo actually comes in. Leaves out JPEG, which has no transparency
    /// to lose, and HEIC, which can hold it but in practice is a camera photo: reading the original
    /// would swap every iPhone photo's small preview for a full decode in the transcript.
    private static let logoMimeTypes: Set<String> = [
        "image/png", "image/x-png", "image/webp", "image/gif", "image/avif", "image/tiff"
    ]

    static func generatePDFThumbnail(from data: Data) -> Data? {
        guard let document = PDFDocument(data: data),
              let firstPage = document.page(at: 0) else {
            return nil
        }
        
        let pageRect = firstPage.bounds(for: .mediaBox)
        guard pageRect.width > 0, pageRect.height > 0,
              pageRect.width.isFinite, pageRect.height.isFinite else {
            Log.debug("ImageProcessor: Invalid PDF page bounds \(pageRect)", category: .attachment)
            return nil
        }

        let scale = min(maxThumbnailDimension / max(pageRect.width, pageRect.height), 1.0)
        let thumbnailSize = CGSize(width: pageRect.width * scale, height: pageRect.height * scale)
        guard thumbnailSize.width > 0, thumbnailSize.height > 0,
              thumbnailSize.width.isFinite, thumbnailSize.height.isFinite else {
            Log.debug("ImageProcessor: Skipping PDF thumbnail with invalid target size \(thumbnailSize)", category: .attachment)
            return nil
        }
        
        return PlatformImageRenderer.opaqueJPEGData(
            pixelSize: thumbnailSize,
            compressionQuality: jpegCompressionQuality
        ) { context in
            context.setFillColor(PlatformColor.white.cgColor)
            context.fill(CGRect(origin: .zero, size: thumbnailSize))

            context.translateBy(x: 0, y: thumbnailSize.height)
            context.scaleBy(x: scale, y: -scale)

            firstPage.draw(with: .mediaBox, to: context)
        }
    }
    
    static func getPDFPageCount(from data: Data) -> Int? {
        guard let document = PDFDocument(data: data) else { return nil }
        return document.pageCount
    }
    
    static func getImageDimensions(from data: Data) -> CGSize? {
        guard let image = PlatformImage(data: data) else { return nil }
        return image.pixelSize
    }
}
