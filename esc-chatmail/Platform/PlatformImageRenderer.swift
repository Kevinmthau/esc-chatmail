#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Draws the app's generated thumbnails into a bitmap at one pixel per point and returns it as
/// JPEG data. iOS keeps the UIKit renderers it has always used; the Mac draws into a Core Graphics
/// bitmap and encodes it with ImageIO, because AppKit has no `UIGraphics` image context.
enum PlatformImageRenderer {
    /// `image` drawn to fill `pixelSize`. Where the image is transparent the JPEG shows white,
    /// which is what both platforms' JPEG encoders put behind it.
    static func jpegData(
        drawing image: PlatformImage,
        pixelSize: CGSize,
        compressionQuality: CGFloat
    ) -> Data? {
        #if canImport(UIKit)
        // These limits are pixels, not display points. The default renderer
        // scale would multiply both dimensions on Retina devices.
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: pixelSize, format: format)
        return renderer.jpegData(withCompressionQuality: compressionQuality) { _ in
            image.draw(in: CGRect(origin: .zero, size: pixelSize))
        }
        #else
        guard let context = bitmapContext(pixelSize: pixelSize, isOpaque: false) else { return nil }
        // Unflipped, so `draw(in:)` puts the image upright, as UIKit's renderer does.
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        image.draw(in: CGRect(origin: .zero, size: pixelSize))
        NSGraphicsContext.restoreGraphicsState()
        return jpegData(of: context, compressionQuality: compressionQuality)
        #endif
    }

    /// An opaque bitmap of `pixelSize` painted by `draw`, which gets UIKit's image-context
    /// coordinates on both platforms: origin at the top left, y growing downward.
    static func opaqueJPEGData(
        pixelSize: CGSize,
        compressionQuality: CGFloat,
        draw: (CGContext) -> Void
    ) -> Data? {
        #if canImport(UIKit)
        UIGraphicsBeginImageContextWithOptions(pixelSize, true, 1.0)
        defer { UIGraphicsEndImageContext() }

        guard let context = UIGraphicsGetCurrentContext() else { return nil }
        draw(context)

        guard let image = UIGraphicsGetImageFromCurrentImageContext() else { return nil }
        return image.jpegData(compressionQuality: compressionQuality)
        #else
        guard let context = bitmapContext(pixelSize: pixelSize, isOpaque: true) else { return nil }
        // A Core Graphics bitmap starts at the bottom left; flip it to match UIKit.
        context.translateBy(x: 0, y: CGFloat(context.height))
        context.scaleBy(x: 1, y: -1)
        draw(context)
        return jpegData(of: context, compressionQuality: compressionQuality)
        #endif
    }

    #if !canImport(UIKit)
    /// An 8-bit sRGB bitmap covering `pixelSize`, rounded up to whole pixels as UIKit's renderers do.
    private static func bitmapContext(pixelSize: CGSize, isOpaque: Bool) -> CGContext? {
        guard pixelSize.width.isFinite, pixelSize.height.isFinite else { return nil }
        let width = Int(pixelSize.width.rounded(.up))
        let height = Int(pixelSize.height.rounded(.up))
        guard width > 0, height > 0,
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else {
            return nil
        }
        let alphaInfo: CGImageAlphaInfo = isOpaque ? .noneSkipLast : .premultipliedLast
        return CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: alphaInfo.rawValue
        )
    }

    private static func jpegData(of context: CGContext, compressionQuality: CGFloat) -> Data? {
        guard let cgImage = context.makeImage() else { return nil }
        return PlatformImage(cgImage: cgImage).jpegData(compressionQuality: compressionQuality)
    }
    #endif
}
