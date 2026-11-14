import UniformTypeIdentifiers
import XCTest
@testable import esc_chatmail

/// A pasted image that came as TIFF is written as PNG (`PastedImagePNGEncoder`). ImageIO
/// only, so this runs in the iOS suite and in `Mac.xctestplan`.
final class PastedImagePNGEncoderTests: XCTestCase {
    /// Revert-check: returning `data` as it came from `PastedImagePNGEncoder.pngData` makes
    /// the type assertion fail: the pasted image is a TIFF again, which the draft's import
    /// attaches as a plain file.
    func testPNGData_fromATIFF_isAPNGOfTheSameSize() throws {
        let size = CGSize(width: 60, height: 40)
        let tiff = try TestImageData.encoded(as: .tiff, pixelSizes: [size])
        XCTAssertEqual(TestImageData.typeIdentifier(of: tiff), UTType.tiff.identifier)

        let png = try XCTUnwrap(PastedImagePNGEncoder.pngData(from: tiff))

        XCTAssertEqual(TestImageData.typeIdentifier(of: png), UTType.png.identifier)
        XCTAssertEqual(TestImageData.pixelSizes(of: png), [size])
    }

    /// An `NSImage` with a 1x and a 2x representation is copied as one TIFF holding both.
    ///
    /// Revert-check: encoding index 0 in `PastedImagePNGEncoder.pngData`, in place of
    /// `largestImageIndex`, makes this fail: the smaller picture is the one attached.
    func testPNGData_fromATIFFHoldingTwoSizes_isTheLarger() throws {
        let small = CGSize(width: 16, height: 16)
        let large = CGSize(width: 32, height: 32)
        let tiff = try TestImageData.encoded(as: .tiff, pixelSizes: [small, large])
        // Both are in the file, the smaller first.
        XCTAssertEqual(TestImageData.pixelSizes(of: tiff), [small, large])

        let png = try XCTUnwrap(PastedImagePNGEncoder.pngData(from: tiff))

        XCTAssertEqual(TestImageData.pixelSizes(of: png), [large])
    }

    /// Bytes that claim to be an image and are not: the paste is then refused, where the
    /// bytes would otherwise be written to a file and handed to the import.
    ///
    /// Revert-check: returning `data` from `PastedImagePNGEncoder.pngData` where no image
    /// could be read makes this fail.
    func testPNGData_fromBytesThatAreNoImage_isNil() {
        XCTAssertNil(PastedImagePNGEncoder.pngData(from: Data("not an image".utf8)))
        XCTAssertNil(PastedImagePNGEncoder.pngData(from: Data()))
    }
}
