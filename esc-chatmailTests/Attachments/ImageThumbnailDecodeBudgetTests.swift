import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import esc_chatmail

/// Pins the pixel budget on decoding a sender's image: `ImageProcessor.generateThumbnail` reads
/// the size from the header and refuses past `maxThumbnailSourcePixelCount` before decoding, and
/// `AttachmentCacheActor`'s downsample of an original holds the same budget. Made with ImageIO
/// alone, so it also builds for the Mac, but keep it out of `Mac.xctestplan`: the cache test
/// writes into `Attachments`, which in a Mac test host is the real container's. The iPhone's
/// within-limit byte identity and white flattening are pinned further in `ImageBackdropPolicyTests`.
final class ImageThumbnailDecodeBudgetTests: XCTestCase {

    // MARK: - The plan

    /// Revert-check: fails if `imageThumbnailPlan` stops asking `isWithinDecodeBudget`, or
    /// compares the longest side with `>=`.
    func testImageThumbnailPlan_bySize_refusesPastTheBudgetAndKeepsSmallOriginals() {
        func plan(_ width: CGFloat, _ height: CGFloat) -> ImageProcessor.ImageThumbnailPlan {
            ImageProcessor.imageThumbnailPlan(sourcePixelSize: CGSize(width: width, height: height))
        }
        XCTAssertEqual(plan(1_600, 1_600), .original)
        XCTAssertEqual(plan(1_601, 10), .downsampled)
        XCTAssertEqual(plan(8_064, 6_048), .downsampled, "a 48-megapixel camera photo keeps its preview")
        XCTAssertEqual(plan(16_000, 3_900), .downsampled, "a 63-megapixel panorama keeps its preview")
        XCTAssertEqual(plan(8_192, 8_192), .downsampled)
        XCTAssertEqual(plan(8_192, 8_193), .refused)
        XCTAssertEqual(plan(30_000, 30_000), .refused)
        XCTAssertEqual(plan(0, 100), .refused)
        XCTAssertEqual(plan(.nan, 100), .refused)
        XCTAssertEqual(plan(.infinity, 1), .refused)
    }

    // MARK: - generateThumbnail

    /// The review's pin: a PNG declaring 30,000 x 30,000 gets no preview. The file is valid and
    /// under a megabyte; decoded it is 900 MB, and drawn as the old path drew it, 3.6 GB.
    /// HONEST SCOPE: this test is not revert-checked, because a revert decodes that picture in
    /// the test host. The next test is the revert-check that the refusal is the budget's.
    func testGenerateThumbnail_validPNGOfThirtyThousandSquare_returnsNil() throws {
        let bomb = try TestImageData.zeroFilledGrayPNG(width: 30_000, height: 30_000)
        XCTAssertLessThan(bomb.count, 1_000_000)
        let source = try XCTUnwrap(CGImageSourceCreateWithData(bomb as CFData, nil))
        XCTAssertEqual(ImageProcessor.sourcePixelSize(of: source), CGSize(width: 30_000, height: 30_000))

        XCTAssertNil(ImageProcessor.generateThumbnail(from: bomb, mimeType: "image/png"))
    }

    /// A picture that decodes perfectly well is still refused once it is past the budget.
    /// Revert-check: fails if `generateImageThumbnail` makes a preview whatever the plan says.
    func testGenerateImageThumbnail_decodableImagePastTheBudget_returnsNil() throws {
        let image = try TestImageData.encoded(as: .png, pixelSizes: [CGSize(width: 2_000, height: 1_000)])

        XCTAssertNotNil(ImageProcessor.generateImageThumbnail(from: image))
        XCTAssertNil(ImageProcessor.generateImageThumbnail(from: image, maxSourcePixelCount: 1_999_999))
    }

    func testGenerateThumbnail_imageWithinTheLimit_isTheOriginalsBytes() throws {
        let image = try TestImageData.encoded(as: .png, pixelSizes: [CGSize(width: 1_600, height: 900)])
        XCTAssertEqual(ImageProcessor.generateThumbnail(from: image, mimeType: "image/png"), image)
    }

    func testGenerateThumbnail_notAnImage_returnsNil() {
        XCTAssertNil(ImageProcessor.generateThumbnail(from: Data("not an image".utf8), mimeType: "image/png"))
        XCTAssertNil(ImageProcessor.generateThumbnail(from: Data(), mimeType: "image/png"))
    }

    /// Past the limit the preview is decoded straight to its size by ImageIO and drawn into the
    /// renderer: this pins that it comes out at the limit, upright, and flattened onto white.
    /// Revert-check: drop the flip in `downsampledImageThumbnail` and the black band is at the
    /// bottom; drop the white fill and the transparent half is black.
    func testGenerateThumbnail_imagePastTheLimit_isAnUprightJPEGOnWhiteAtTheLimit() throws {
        // Top half black, bottom half transparent. A CGContext's y grows upward, so the top
        // half of the picture is y 500 to 1,000.
        let context = try XCTUnwrap(CGContext(
            data: nil, width: 2_000, height: 1_000, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(red: 0, green: 0, blue: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 500, width: 2_000, height: 500))
        let original = try encodedPNG(XCTUnwrap(context.makeImage()))

        let thumbnail = try XCTUnwrap(ImageProcessor.generateThumbnail(from: original, mimeType: "image/png"))

        XCTAssertEqual(TestImageData.typeIdentifier(of: thumbnail), UTType.jpeg.identifier)
        XCTAssertEqual(TestImageData.pixelSizes(of: thumbnail), [CGSize(width: 1_600, height: 800)])
        let pixels = try rgbaPixels(of: thumbnail)
        let top = pixels.color(x: 800, y: 100)
        let bottom = pixels.color(x: 800, y: 700)
        XCTAssertTrue(top.allSatisfy { $0 < 30 }, "top \(top)")
        XCTAssertTrue(bottom.allSatisfy { $0 > 225 }, "bottom \(bottom)")
    }

    // MARK: - AttachmentCacheActor's downsample of an original

    /// The bubble reads an original in place of a flattened preview, so the cache's downsample
    /// must refuse what the preview refused. 8,200 squared is just past 8,192 squared.
    /// Revert-check: remove the `isWithinDecodeBudget` guard in
    /// `AttachmentCacheActor.downsampleImage` and the image comes back.
    func testLoadDownsampledImage_originalPastTheBudget_returnsNil() async throws {
        AttachmentPaths.setupDirectories()
        let small = try TestImageData.zeroFilledGrayPNG(width: 2_000, height: 2_000)
        let large = try TestImageData.zeroFilledGrayPNG(width: 8_200, height: 8_200)
        let smallID = "local_\(UUID().uuidString)"
        let largeID = "local_\(UUID().uuidString)"
        let smallPath = AttachmentPaths.originalPath(idOrUUID: smallID, ext: "png")
        let largePath = AttachmentPaths.originalPath(idOrUUID: largeID, ext: "png")
        XCTAssertTrue(AttachmentPaths.saveData(small, to: smallPath))
        XCTAssertTrue(AttachmentPaths.saveData(large, to: largePath))
        defer { [smallPath, largePath].forEach { AttachmentPaths.deleteFile(at: $0) } }
        let cache = AttachmentCacheActor()
        let target = CGSize(width: 200, height: 200)

        let withinBudget = await cache.loadDownsampledImage(for: smallID, from: smallPath, targetSize: target)
        let pastBudget = await cache.loadDownsampledImage(for: largeID, from: largePath, targetSize: target)

        XCTAssertNotNil(withinBudget)
        XCTAssertNil(pastBudget)
    }

    // MARK: - Helpers

    private func encodedPNG(_ image: CGImage) throws -> Data {
        let data = NSMutableData()
        let destination = try XCTUnwrap(
            CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)
        )
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }

    private struct RGBAPixels {
        let bytes: [UInt8]
        let width: Int

        /// Red, green and blue at a point counted from the top left.
        func color(x: Int, y: Int) -> [UInt8] {
            let offset = (y * width + x) * 4
            return Array(bytes[offset..<offset + 3])
        }
    }

    private func rgbaPixels(of data: Data) throws -> RGBAPixels {
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        try bytes.withUnsafeMutableBytes { buffer in
            let context = try XCTUnwrap(CGContext(
                data: buffer.baseAddress, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ))
            // A bitmap context's first row in memory is the top of the picture.
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return RGBAPixels(bytes: bytes, width: image.width)
    }
}
