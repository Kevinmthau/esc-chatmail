import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest

/// Encoded pictures for tests, made and read with ImageIO so they are the same on iOS and on
/// the Mac.
enum TestImageData {
    /// One file of `type` holding a solid picture at each of `pixelSizes`, in that order. A
    /// TIFF can hold several; most types hold one.
    static func encoded(as type: UTType, pixelSizes: [CGSize]) throws -> Data {
        let data = NSMutableData()
        let destination = try XCTUnwrap(
            CGImageDestinationCreateWithData(data, type.identifier as CFString, pixelSizes.count, nil),
            "ImageIO cannot write \(type.identifier)"
        )
        for pixelSize in pixelSizes {
            CGImageDestinationAddImage(destination, try solidImage(pixelSize: pixelSize), nil)
        }
        guard CGImageDestinationFinalize(destination) else {
            throw XCTSkip("ImageIO could not encode \(type.identifier) here")
        }
        return data as Data
    }

    /// What a test picture is of.
    enum Picture {
        /// One color: a few hundred bytes as PNG, and more than that as JPEG.
        case flat
        /// A gradient with fine noise over it, which is what a photograph is to an encoder:
        /// PNG barely compresses it and JPEG does.
        case photograph
    }

    /// One file of `type` holding `picture`, drawn in a bitmap that has an alpha channel or
    /// has none. Every pixel is opaque either way: what differs is what the file says.
    static func encoded(
        as type: UTType,
        pixelSize: CGSize,
        picture: Picture,
        hasAlphaChannel: Bool
    ) throws -> Data {
        let data = NSMutableData()
        let destination = try XCTUnwrap(
            CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil),
            "ImageIO cannot write \(type.identifier)"
        )
        let image = try image(pixelSize: pixelSize, picture: picture, hasAlphaChannel: hasAlphaChannel)
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw XCTSkip("ImageIO could not encode \(type.identifier) here")
        }
        return data as Data
    }

    private static func image(pixelSize: CGSize, picture: Picture, hasAlphaChannel: Bool) throws -> CGImage {
        let width = Int(pixelSize.width)
        let height = Int(pixelSize.height)
        let alpha: CGImageAlphaInfo = hasAlphaChannel ? .premultipliedLast : .noneSkipLast
        let context = try XCTUnwrap(CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: alpha.rawValue
        ))
        switch picture {
        case .flat:
            context.setFillColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1)
            context.fill(CGRect(origin: .zero, size: pixelSize))
        case .photograph:
            let bytesPerRow = context.bytesPerRow
            let pixels = try XCTUnwrap(context.data).bindMemory(to: UInt8.self, capacity: bytesPerRow * height)
            // The same picture every run: the noise is counted out, not drawn at random.
            var seed: UInt32 = 12345
            for y in 0..<height {
                for x in 0..<width {
                    seed = seed &* 1_664_525 &+ 1_013_904_223
                    let noise = Int((seed >> 24) & 0x1F)
                    let offset = y * bytesPerRow + x * 4
                    pixels[offset] = UInt8(clamping: x * 200 / width + noise)
                    pixels[offset + 1] = UInt8(clamping: y * 200 / height + noise)
                    pixels[offset + 2] = UInt8(clamping: 100 + noise)
                    pixels[offset + 3] = 255
                }
            }
        }
        return try XCTUnwrap(context.makeImage())
    }

    /// The type ImageIO reads `data` as, or nil where it is no image.
    static func typeIdentifier(of data: Data) -> String? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0 else {
            return nil
        }
        return CGImageSourceGetType(source) as String?
    }

    /// The size in pixels of each picture `data` holds, in the file's order.
    static func pixelSizes(of data: Data) -> [CGSize] {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return [] }
        return (0..<CGImageSourceGetCount(source)).compactMap { index in
            guard let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? Int,
                  let height = properties[kCGImagePropertyPixelHeight] as? Int else {
                return nil
            }
            return CGSize(width: width, height: height)
        }
    }

    private static func solidImage(pixelSize: CGSize) throws -> CGImage {
        let context = try XCTUnwrap(CGContext(
            data: nil,
            width: Int(pixelSize.width),
            height: Int(pixelSize.height),
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1)
        context.fill(CGRect(origin: .zero, size: pixelSize))
        return try XCTUnwrap(context.makeImage())
    }
}
