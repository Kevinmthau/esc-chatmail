import Compression
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

    /// A valid PNG of `width` x `height` black 8-bit gray pixels, made without ever holding the
    /// pixels: its rows are all zeros, deflated as a stream. 30,000 x 30,000 is about 875 KB and
    /// a couple of seconds to make, which is what a sender can mail to make a reader that decodes
    /// the whole picture allocate 900 MB for it (3.6 GB drawn in RGBA). ImageIO reports the size
    /// of such a file; it does not for a header with no data behind it.
    static func zeroFilledGrayPNG(width: UInt32, height: UInt32) throws -> Data {
        func bigEndian(_ value: UInt32) -> [UInt8] {
            [UInt8(value >> 24 & 0xFF), UInt8(value >> 16 & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)]
        }
        func chunk(_ type: String, _ body: [UInt8]) -> [UInt8] {
            let typeAndBody = Array(type.utf8) + body
            return bigEndian(UInt32(body.count)) + typeAndBody + bigEndian(crc32(typeAndBody))
        }
        // Each row is a filter byte (0, none) and one zero byte per pixel.
        let rawByteCount = Int(height) * (Int(width) + 1)
        // zlib: a header, the raw DEFLATE stream, and the Adler-32 of the raw bytes, which for
        // all zeros is A = 1 and B = the count, modulo 65,521.
        let zlibStream = [0x78, 0x9C]
            + (try deflatedZeros(count: rawByteCount))
            + bigEndian(UInt32(rawByteCount % 65_521) << 16 | 1)
        // Bit depth 8, color type 0 (gray), deflate, adaptive filtering, no interlace.
        let header = bigEndian(width) + bigEndian(height) + [8, 0, 0, 0, 0]
        let signature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        return Data(signature + chunk("IHDR", header) + chunk("IDAT", zlibStream) + chunk("IEND", []))
    }

    /// `count` zero bytes as raw DEFLATE, fed to the encoder a megabyte at a time.
    private static func deflatedZeros(count: Int) throws -> [UInt8] {
        let stream = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
        defer { stream.deallocate() }
        guard compression_stream_init(stream, COMPRESSION_STREAM_ENCODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else {
            throw XCTSkip("Compression could not start a DEFLATE stream here")
        }
        defer { compression_stream_destroy(stream) }

        let zeros = [UInt8](repeating: 0, count: 1 << 20)
        var output = [UInt8](repeating: 0, count: 1 << 16)
        var deflated: [UInt8] = []
        var remaining = count
        var status = COMPRESSION_STATUS_OK
        try zeros.withUnsafeBufferPointer { source in
            try output.withUnsafeMutableBufferPointer { destination in
                stream.pointee.src_size = 0
                while status != COMPRESSION_STATUS_END {
                    if stream.pointee.src_size == 0, remaining > 0 {
                        let take = min(remaining, source.count)
                        remaining -= take
                        stream.pointee.src_ptr = source.baseAddress!
                        stream.pointee.src_size = take
                    }
                    stream.pointee.dst_ptr = destination.baseAddress!
                    stream.pointee.dst_size = destination.count
                    let flags = remaining == 0 ? Int32(COMPRESSION_STREAM_FINALIZE.rawValue) : 0
                    status = compression_stream_process(stream, flags)
                    guard status != COMPRESSION_STATUS_ERROR else {
                        throw XCTSkip("Compression failed to deflate here")
                    }
                    deflated.append(contentsOf: destination[0..<(destination.count - stream.pointee.dst_size)])
                }
            }
        }
        return deflated
    }

    /// PNG's CRC-32 (ISO 3309), from a table made once.
    private static func crc32(_ bytes: [UInt8]) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in bytes {
            crc = crc32Table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
        }
        return crc ^ 0xFFFF_FFFF
    }

    private static let crc32Table: [UInt32] = (0..<256).map { index in
        var value = UInt32(index)
        for _ in 0..<8 {
            value = value & 1 == 1 ? (value >> 1) ^ 0xEDB8_8320 : value >> 1
        }
        return value
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
