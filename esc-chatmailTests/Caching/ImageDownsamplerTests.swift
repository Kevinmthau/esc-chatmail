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
}
