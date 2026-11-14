import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Re-encodes a pasted image as PNG before it is written to its file (`PastedImageFile`,
/// `MacReplyTextView.imageData`).
///
/// For an image the pasteboard has only as TIFF, which is what an app writes when it copies
/// an `NSImage`. Measured 2026-11-14 on pasteboards of a probe's own: one given an `NSImage`,
/// or only TIFF, offers no PNG, while one given PNG offers TIFF as well.
///
/// Written as it came, such an image was `Pasted Image.tiff`, and the draft's import does not
/// take that as an image: `DocumentAttachmentImporter` knows no MIME type for the extension.
/// It was attached as `application/octet-stream`, with no thumbnail and no size, and sent
/// uncompressed: 20.7 MB for 2880 by 1800 pixels, and anything much larger was refused as
/// over the attachment budget. As PNG it is an image to the import and to whoever gets the
/// mail, and a fraction of the size, with nothing lost.
enum PastedImagePNGEncoder {
    /// `data` as PNG, or nil where it holds no image that can be read.
    ///
    /// A TIFF can hold one picture at several sizes (an `NSImage` with a 1x and a 2x
    /// representation writes both), and the largest is the one encoded. Its color profile and
    /// resolution go with it.
    static func pngData(from data: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let index = largestImageIndex(in: source) else {
            return nil
        }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            return nil
        }
        CGImageDestinationAddImageFromSource(destination, source, index, nil)
        guard CGImageDestinationFinalize(destination), output.length > 0 else { return nil }
        return output as Data
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
