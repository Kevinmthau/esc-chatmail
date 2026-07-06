import XCTest
@testable import esc_chatmail

final class AttachmentPathsTests: XCTestCase {
    func testFileExtension_videoMimeTypes() {
        XCTAssertEqual(AttachmentPaths.fileExtension(for: "video/mp4"), "mp4")
        XCTAssertEqual(AttachmentPaths.fileExtension(for: "video/quicktime"), "mov")
        XCTAssertEqual(AttachmentPaths.fileExtension(for: "video/x-m4v"), "m4v")
    }

    func testFileExtension_videoFallback() {
        XCTAssertEqual(AttachmentPaths.fileExtension(for: "video/unknown"), "mp4")
    }
}
