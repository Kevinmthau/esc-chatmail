#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
import ImageIO
import UniformTypeIdentifiers
#endif

#if canImport(UIKit)
/// The app's bitmap image: UIKit's `UIImage` on iOS, so nothing about iOS images changes.
typealias PlatformImage = UIImage
#elseif canImport(AppKit)
/// The app's bitmap image: AppKit's `NSImage` on the Mac.
///
/// The extension below gives `NSImage` the few `UIImage` members the shared code calls, with
/// UIKit's meaning, so that code compiles unchanged on both platforms. Anything else stays
/// platform-specific and belongs in this folder too.
typealias PlatformImage = NSImage

extension NSImage {
    /// One point per pixel, as `UIImage(cgImage:)` makes.
    convenience init(cgImage: CGImage) {
        self.init(cgImage: cgImage, size: .zero)
    }

    /// The bitmap the image draws from, as `UIImage.cgImage`.
    var cgImage: CGImage? {
        cgImage(forProposedRect: nil, context: nil, hints: nil)
    }

    /// Pixels per point, as `UIImage.scale`. Pixel math has to multiply `size` by this on the
    /// Mac: `NSImage(data:)` sizes an image from its DPI, so a 144-dpi file reports half its
    /// pixel size, where `UIImage(data:)` always reports the pixel size at scale 1.
    var scale: CGFloat {
        // The image draws from its largest representation.
        guard size.width > 0,
              let pixelWidth = representations.map(\.pixelsWide).max(),
              pixelWidth > 0 else {
            return 1
        }
        return CGFloat(pixelWidth) / size.width
    }

    /// As `UIImage.jpegData(compressionQuality:)`. ImageIO flattens transparency onto white,
    /// which is also what UIKit's JPEG encoding does.
    func jpegData(compressionQuality: CGFloat) -> Data? {
        encodedData(
            type: .jpeg,
            properties: [kCGImageDestinationLossyCompressionQuality: compressionQuality]
        )
    }

    /// As `UIImage.pngData()`.
    func pngData() -> Data? {
        encodedData(type: .png, properties: [:])
    }

    private func encodedData(type: UTType, properties: [CFString: Any]) -> Data? {
        guard let cgImage else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data,
            type.identifier as CFString,
            1,
            nil
        ) else {
            return nil
        }
        CGImageDestinationAddImage(destination, cgImage, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}
#endif

extension PlatformImage {
    /// The image's size in pixels. A `PlatformImage(data:)` on iOS has scale 1, so there this is
    /// exactly `size`; on the Mac it undoes the DPI sizing described on `scale`.
    var pixelSize: CGSize {
        CGSize(width: size.width * scale, height: size.height * scale)
    }
}
