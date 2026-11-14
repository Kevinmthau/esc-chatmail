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
