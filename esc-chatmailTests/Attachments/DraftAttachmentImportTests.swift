import XCTest
import UIKit
import ImageIO
import UniformTypeIdentifiers
@testable import esc_chatmail

@MainActor
final class DraftAttachmentImportTests: XCTestCase {
    func testResizeLimitIsMeasuredInPixelsOnRetinaDisplays() throws {
        let data = try png(width: 100, height: 50)
        let output = ImageProcessor.processImage(data: data, maxDimension: 24)
        let processed = try XCTUnwrap(output.processed)
        let image = try XCTUnwrap(UIImage(data: processed)?.cgImage)

        XCTAssertEqual(image.width, 24)
        XCTAssertEqual(image.height, 12)
        XCTAssertEqual(output.size, CGSize(width: 24, height: 12))
    }

    func testSmallPNGKeepsOriginalBytesAndMatchingMetadata() throws {
        let data = try png(width: 30, height: 20)
        let prepared = try DraftAttachmentImport.prepareImage(
            data: data, filename: "screenshot.png", existingByteCount: 0
        )

        XCTAssertEqual(prepared.data, data)
        XCTAssertEqual(prepared.mimeType, "image/png")
        XCTAssertEqual(prepared.filename(replacingExtensionOf: "screenshot.png"), "screenshot.png")
        XCTAssertEqual(try encodedType(prepared.data), UTType.png.identifier)
    }

    func testLargePNGUsesJPEGMetadataAfterResizing() throws {
        let prepared = try DraftAttachmentImport.prepareImage(
            data: png(width: 4100, height: 20), filename: "panorama.png", existingByteCount: 0
        )

        XCTAssertEqual(prepared.mimeType, "image/jpeg")
        XCTAssertEqual(try encodedType(prepared.data), UTType.jpeg.identifier)
        XCTAssertEqual(UTType(filenameExtension: prepared.fileExtension), .jpeg)
        XCTAssertTrue(prepared.filename(replacingExtensionOf: "panorama.png").hasSuffix("." + prepared.fileExtension))
        XCTAssertEqual(try XCTUnwrap(UIImage(data: prepared.data)?.cgImage).width, 4096)
    }

    func testSmallHEICKeepsMetadataMatchingEncodedBytes() throws {
        let image = try XCTUnwrap(UIImage(data: png(width: 30, height: 20))?.cgImage)
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.heic.identifier as CFString, 1, nil) else {
            throw XCTSkip("HEIC encoding is unavailable on this simulator")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw XCTSkip("HEIC encoding is unavailable on this simulator")
        }
        let prepared = try DraftAttachmentImport.prepareImage(
            data: data as Data, filename: "photo.heic", existingByteCount: 0
        )

        XCTAssertEqual(prepared.data, data as Data)
        XCTAssertEqual(prepared.mimeType, "image/heic")
        XCTAssertEqual(try encodedType(prepared.data), UTType.heic.identifier)
        XCTAssertEqual(UTType(filenameExtension: prepared.fileExtension), .heic)
    }

    func testCorruptPhotoProducesActionableFailure() {
        XCTAssertThrowsError(try DraftAttachmentImport.prepareImage(
            data: Data("not an image".utf8), filename: "Photo 2", existingByteCount: 0
        )) { error in
            XCTAssertTrue(error.localizedDescription.contains("Photo 2"))
            XCTAssertTrue(error.localizedDescription.contains("could not be read"))
        }
    }

    func testCombinedBudgetRejectsBeforeDecodingInvalidImage() {
        XCTAssertThrowsError(try DraftAttachmentImport.prepareImage(
            data: Data([0]), filename: "extra.png",
            existingByteCount: DraftAttachmentImport.maximumTotalBytes
        )) { error in
            XCTAssertTrue(error.localizedDescription.contains("combined attachment budget"))
        }
    }

    func testBudgetBoundaryAndOverflowAreHandled() throws {
        let maximum = DraftAttachmentImport.maximumTotalBytes
        XCTAssertNoThrow(try DraftAttachmentImport.validateSize(
            byteCount: 1, existingByteCount: maximum - 1, filename: "last.pdf"
        ))
        XCTAssertThrowsError(try DraftAttachmentImport.validateSize(
            byteCount: Int64.max, existingByteCount: 1, filename: "large.pdf"
        ))
        XCTAssertGreaterThan(DraftAttachmentImport.totalByteCount([Int64.max, Int64.max]), maximum)
    }

    func testDocumentPreflightRejectsOversizedFileWithoutLoadingItsData() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".pdf")
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertTrue(FileManager.default.createFile(atPath: url.path, contents: Data()))
        let file = try FileHandle(forWritingTo: url)
        try file.truncate(atOffset: UInt64(DraftAttachmentImport.maximumTotalBytes + 1))
        try file.close()

        XCTAssertThrowsError(try DraftAttachmentImport.preflightDocument(at: url, existingByteCount: 0)) { error in
            XCTAssertTrue(error.localizedDescription.contains(url.lastPathComponent))
            XCTAssertTrue(error.localizedDescription.contains("combined attachment budget"))
        }
    }

    private func png(width: Int, height: Int) throws -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(
            size: CGSize(width: width, height: height), format: format
        ).pngData { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
    }

    private func encodedType(_ data: Data) throws -> String {
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        return try XCTUnwrap(CGImageSourceGetType(source)) as String
    }
}
