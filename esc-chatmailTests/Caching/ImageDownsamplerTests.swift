#if os(iOS)
import XCTest
import UIKit
@testable import esc_chatmail

final class ImageDownsamplerTests: XCTestCase {

    private func makeImageData(width: Int, height: Int) throws -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format)
        let image = renderer.image { context in
            UIColor.systemTeal.setFill()
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
        return try XCTUnwrap(image.jpegData(compressionQuality: 0.8))
    }

    private func pixelSize(of image: UIImage) -> CGSize {
        CGSize(width: image.size.width * image.scale, height: image.size.height * image.scale)
    }

    func testDecode_capsLargeImageToMaxDimension() throws {
        let data = try makeImageData(width: 3000, height: 2000)

        let image = try XCTUnwrap(ImageDownsampler.decode(data: data, maxPixelDimension: 1024))

        let size = pixelSize(of: image)
        XCTAssertLessThanOrEqual(max(size.width, size.height), 1024)
        // Aspect ratio preserved (3:2).
        XCTAssertEqual(size.width / size.height, 1.5, accuracy: 0.05)
    }

    func testDecode_smallImagePassesThroughAtFullResolution() throws {
        let data = try makeImageData(width: 400, height: 300)

        let image = try XCTUnwrap(ImageDownsampler.decode(data: data, maxPixelDimension: 1024))

        let size = pixelSize(of: image)
        XCTAssertEqual(size.width, 400, accuracy: 1)
        XCTAssertEqual(size.height, 300, accuracy: 1)
    }

    func testDecode_defaultCapCoversFullWidthNewsletterHero() throws {
        // A 3× full-width hero (~1250px) must not be softened by the default cap.
        let data = try makeImageData(width: 1250, height: 500)

        let image = try XCTUnwrap(ImageDownsampler.decode(data: data))

        let size = pixelSize(of: image)
        XCTAssertEqual(size.width, 1250, accuracy: 1)
    }

    func testDecode_invalidData_returnsNil() {
        XCTAssertNil(ImageDownsampler.decode(data: Data([0x00, 0x01, 0x02]), maxPixelDimension: 1024))
        XCTAssertNil(ImageDownsampler.decode(data: Data(), maxPixelDimension: 1024))
    }

    // MARK: - The source-pixel budget

    /// The bytes are a sender's, and the header names the size before anything is decoded:
    /// past the budget the image is refused, and the same bytes decode under a budget that
    /// takes them in.
    ///
    /// Revert-check: the `ImageProcessor.isWithinDecodeBudget` term of the guard in
    /// `ImageDownsampler.decode`. Without it the image is decoded to the cap.
    func testDecode_imageOfMorePixelsThanTheBudget_returnsNil() throws {
        let data = try makeImageData(width: 2000, height: 1500)

        XCTAssertNil(ImageDownsampler.decode(data: data, maxSourcePixelCount: 1_000_000))
        XCTAssertNotNil(ImageDownsampler.decode(data: data, maxSourcePixelCount: 3_000_000))
    }

    /// The default budget is the attachment previews' (`ImageProcessor`), and a valid image
    /// just past it, which is small as a file because zeros compress, is refused.
    func testDecode_validImageJustPastTheDefaultBudget_returnsNil() throws {
        let data = try TestImageData.zeroFilledGrayPNG(width: 8_200, height: 8_200)
        XCTAssertEqual(TestImageData.pixelSizes(of: data), [CGSize(width: 8_200, height: 8_200)])
        XCTAssertGreaterThan(CGFloat(8_200 * 8_200), ImageProcessor.maxThumbnailSourcePixelCount)

        XCTAssertNil(ImageDownsampler.decode(data: data))
    }

    /// A header with no picture behind it: ImageIO names no size for it, so it cannot be
    /// shown to be within the budget, and it is refused.
    ///
    /// HONEST SCOPE: the review's pinning case, and it does not survive a revert. With an
    /// unreadable size sent on to the thumbnail, and a failed thumbnail to
    /// `PlatformImage(data:)`, as before, these bytes still make no image. No fixture was
    /// found that the old fallback decoded and this refuses, so neither the unreadable-size
    /// refusal nor the dropped full-resolution fallback is pinned by a failing test.
    func testDecode_headerThatNamesNoReadableSize_returnsNil() throws {
        let whole = try TestImageData.zeroFilledGrayPNG(width: 30_000, height: 30_000)
        // The signature, the IHDR chunk (which says 30,000 x 30,000) and the first bytes of
        // the IDAT chunk.
        let headerOnly = whole.prefix(8 + 25 + 64)
        XCTAssertEqual(TestImageData.pixelSizes(of: Data(headerOnly)), [], "premise: no size is reported")

        XCTAssertNil(ImageDownsampler.decode(data: Data(headerOnly)))
    }
}
#endif
