import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Puts a pasted picture's bytes in a form the draft's import takes as an image, before they
/// are written to a file (`PastedImageFile`, `MacReplyTextView`).
///
/// The import knows a few kinds of image by their file extension
/// (`DocumentAttachmentImporter.mimeType(forPathExtension:)`), and a picture of one of those
/// kinds is written as it came. Any other picture is written again as one of them
/// (`reencoded(from:)`): that is TIFF above all, which is what an app writes when it copies an
/// `NSImage`. Measured 2026-11-14 on pasteboards of a probe's own: one given an `NSImage`, or
/// only TIFF, offers no PNG, while one given PNG offers TIFF as well.
///
/// Written as it came, a TIFF was `Pasted Image.tiff`, and the import does not take that as
/// an image: it was attached as `application/octet-stream`, with no thumbnail and no size,
/// and sent uncompressed (20.7 MB for 2880 by 1800 pixels).
enum PastedImageEncoder {
    /// A picture's bytes as they are written to its file, and that file's extension.
    struct Attachable: Equatable {
        let data: Data
        let fileExtension: String
    }

    /// `data` as the import takes it: as it came where the import knows its kind, written
    /// again otherwise. Nil where `data` is no picture ImageIO can read.
    ///
    /// The kind is read from the bytes, never from a name: the bytes can come out of rich
    /// text on the pasteboard, where the name beside them is whatever a page or a sender
    /// called the file.
    static func attachable(from data: Data) -> Attachable? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0 else {
            return nil
        }
        if let identifier = CGImageSourceGetType(source) as String?,
           let fileExtension = UTType(identifier)?.preferredFilenameExtension,
           DocumentAttachmentImporter.mimeType(forPathExtension: fileExtension).hasPrefix("image/") {
            return Attachable(data: data, fileExtension: fileExtension)
        }
        return reencoded(from: source)
    }

    /// `data` written again as PNG or as JPEG (`prefersJPEG`), or nil where it holds no image
    /// that can be read.
    static func reencoded(from data: Data) -> Attachable? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return reencoded(from: source)
    }

    /// A TIFF can hold one picture at several sizes (an `NSImage` with a 1x and a 2x
    /// representation writes both), and the largest is the one encoded. Its color profile and
    /// resolution go with it.
    private static func reencoded(from source: CGImageSource) -> Attachable? {
        guard let index = largestImageIndex(in: source),
              let png = encoded(source, at: index, as: .png, quality: nil) else {
            return nil
        }
        let lossless = Attachable(data: png, fileExtension: "png")
        // A picture with an alpha channel is never written as JPEG, which has none, so its
        // JPEG is not made.
        let pictureHasAlpha = hasAlpha(source, at: index)
        guard !pictureHasAlpha,
              let jpeg = encoded(source, at: index, as: .jpeg, quality: ImageProcessor.jpegCompressionQuality),
              prefersJPEG(hasAlpha: pictureHasAlpha, pngByteCount: png.count, jpegByteCount: jpeg.count) else {
            return lossless
        }
        return Attachable(data: jpeg, fileExtension: "jpg")
    }

    /// Whether a picture that has to be written again is written as JPEG, and not as PNG.
    ///
    /// PNG loses nothing, and for a photograph it is several times the size: measured
    /// 2026-11-14 with ImageIO on a 3000 by 3000 photograph, 6.4 MB as PNG and 0.96 MB as JPEG
    /// at the quality the app uses (`ImageProcessor.jpegCompressionQuality`), where the page's
    /// own file was 0.74 MB. A large enough photograph was over the attachment budget as PNG
    /// and refused. For a page of text it is the other way round: 0.99 MB as PNG and 3.0 MB as
    /// JPEG for 2880 by 1800 pixels, and JPEG smears the letters. So both are made and JPEG is
    /// taken only where it is under half the PNG, which a photograph is and a page of text is
    /// not. Making both took 0.28 s for the photograph, against 0.26 s for the PNG alone.
    ///
    /// - Parameter hasAlpha: The picture has an alpha channel. JPEG has none, so such a
    ///   picture stays PNG whatever the sizes: a logo keeps its transparency.
    static func prefersJPEG(hasAlpha: Bool, pngByteCount: Int, jpegByteCount: Int) -> Bool {
        guard !hasAlpha, jpegByteCount > 0, pngByteCount > 0 else { return false }
        // Compared by division: the counts are whatever the bytes made, and doubling one
        // could overflow, which traps.
        return jpegByteCount <= pngByteCount / 2
    }

    private static func encoded(
        _ source: CGImageSource,
        at index: Int,
        as type: UTType,
        quality: CGFloat?
    ) -> Data? {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output,
            type.identifier as CFString,
            1,
            nil
        ) else {
            return nil
        }
        let options = quality.map { [kCGImageDestinationLossyCompressionQuality: $0] as CFDictionary }
        CGImageDestinationAddImageFromSource(destination, source, index, options)
        guard CGImageDestinationFinalize(destination), output.length > 0 else { return nil }
        return output as Data
    }

    /// Whether the image says it has an alpha channel. A TIFF of a photograph says nothing
    /// (measured 2026-11-14 on the TIFF a web view writes for a JPEG, and on one ImageIO wrote
    /// from a bitmap with no alpha), and one of a picture with transparency says it has.
    private static func hasAlpha(_ source: CGImageSource, at index: Int) -> Bool {
        let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
        return (properties?[kCGImagePropertyHasAlpha] as? Bool) ?? false
    }

    /// The index of the image with the most pixels, or nil where none has a size.
    private static func largestImageIndex(in source: CGImageSource) -> Int? {
        var largest: (index: Int, pixelCount: Double)?
        for index in 0..<CGImageSourceGetCount(source) {
            guard let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? Int,
                  let height = properties[kCGImagePropertyPixelHeight] as? Int,
                  width > 0, height > 0 else {
                continue
            }
            // As doubles: the sizes are whatever the bytes claim, and their product as
            // integers could overflow, which traps.
            let pixelCount = Double(width) * Double(height)
            if pixelCount > (largest?.pixelCount ?? 0) {
                largest = (index, pixelCount)
            }
        }
        return largest?.index
    }
}
