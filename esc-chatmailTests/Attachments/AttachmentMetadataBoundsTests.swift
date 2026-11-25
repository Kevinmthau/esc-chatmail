import CoreGraphics
import XCTest
@testable import esc_chatmail

/// Pins the one conversion every writer of `Attachment.width`, `height` and `pageCount` uses.
/// The end-to-end pin, a 40,000-pixel image through the Gmail download path, is in
/// `AttachmentDownloaderTests`.
final class AttachmentMetadataBoundsTests: XCTestCase {

    /// Revert-check: fails if `persistedImageDimension` clamps after converting to an integer
    /// (`Int(_:)` traps on infinity and NaN, so the test host dies), or rounds differently.
    func testPersistedImageDimension_anySide_isClampedToInt16WithoutTrapping() {
        XCTAssertEqual(AttachmentMetadataBounds.persistedImageDimension(CGFloat(Int16.max) + 10_000), Int16.max)
        XCTAssertEqual(AttachmentMetadataBounds.persistedImageDimension(40_000), Int16.max)
        XCTAssertEqual(AttachmentMetadataBounds.persistedImageDimension(CGFloat(Int16.max)), Int16.max)
        XCTAssertEqual(AttachmentMetadataBounds.persistedImageDimension(1e30), Int16.max)
        XCTAssertEqual(AttachmentMetadataBounds.persistedImageDimension(.infinity), 0)
        XCTAssertEqual(AttachmentMetadataBounds.persistedImageDimension(.nan), 0)
        XCTAssertEqual(AttachmentMetadataBounds.persistedImageDimension(-5), 0)
        XCTAssertEqual(AttachmentMetadataBounds.persistedImageDimension(1_024.4), 1_024)
        XCTAssertEqual(AttachmentMetadataBounds.persistedImageDimension(1_024.5), 1_025)
    }

    /// Revert-check: fails if `persistedImageDimensions` clamps each side on its own (the
    /// panorama is stored as 32,767 x 10,000 and loses its shape), or lets a thin side round to 0.
    func testPersistedImageDimensions_sidePastInt16_scalesBothSidesByOneFactor() {
        let panorama = AttachmentMetadataBounds.persistedImageDimensions(CGSize(width: 40_000, height: 10_000))
        XCTAssertEqual(panorama.width, Int16.max)
        XCTAssertEqual(panorama.height, 8_192)

        let strip = AttachmentMetadataBounds.persistedImageDimensions(CGSize(width: 1, height: 40_000))
        XCTAssertEqual(strip.width, 1)
        XCTAssertEqual(strip.height, Int16.max)

        let hairline = AttachmentMetadataBounds.persistedImageDimensions(CGSize(width: 65_535, height: 1))
        XCTAssertEqual(hairline.width, Int16.max)
        XCTAssertEqual(hairline.height, 1, "a positive side never becomes unknown")
    }

    func testPersistedImageDimensions_withinInt16_isEachSideRounded() {
        let photo = AttachmentMetadataBounds.persistedImageDimensions(CGSize(width: 4_032, height: 3_024.6))
        XCTAssertEqual(photo.width, 4_032)
        XCTAssertEqual(photo.height, 3_025)
    }

    func testPersistedImageDimensions_unusableSide_isZeroAndDoesNotScaleTheOther() {
        let size = AttachmentMetadataBounds.persistedImageDimensions(CGSize(width: CGFloat.nan, height: 40_000))
        XCTAssertEqual(size.width, 0)
        XCTAssertEqual(size.height, Int16.max)

        let infinite = AttachmentMetadataBounds.persistedImageDimensions(CGSize(width: 800, height: CGFloat.infinity))
        XCTAssertEqual(infinite.width, 800)
        XCTAssertEqual(infinite.height, 0)
    }

    func testPersistedPDFPageCount_anyCount_isClampedToInt16() {
        XCTAssertEqual(AttachmentMetadataBounds.persistedPDFPageCount(33_000), Int16.max)
        XCTAssertEqual(AttachmentMetadataBounds.persistedPDFPageCount(Int.max), Int16.max)
        XCTAssertEqual(AttachmentMetadataBounds.persistedPDFPageCount(-1), 0)
        XCTAssertEqual(AttachmentMetadataBounds.persistedPDFPageCount(12), 12)
    }

    /// Every writer of the three attributes goes through the clamp: a trapping `Int16(_:)` or a
    /// clamp of its own at a writer is how the download path came to differ from the others.
    /// Revert-check: put back `Int16(dimensions.width)` in `AttachmentDownloader` and this fails
    /// (as does the end-to-end test, by trapping the host).
    func testWritersOfAttachmentMetadata_convertOnlyThroughTheClamp() throws {
        let writers = [
            "esc-chatmail/Services/Attachments/AttachmentDownloader.swift",
            "esc-chatmail/Services/Sync/Persistence/MessagePersister+Helpers.swift",
            "esc-chatmail/Views/Compose/ComposeInputBar.swift",
            "esc-chatmail/Views/Components/AttachmentPicker.swift",
            "esc-chatmail/Views/Components/DocumentAttachmentImporter.swift"
        ]
        for path in writers {
            let source = try repositorySource(path)
            XCTAssertTrue(source.contains("AttachmentMetadataBounds."), path)
            for forbidden in ["= Int16(", "Int16(clamping:"] {
                XCTAssertFalse(source.contains(forbidden), "\(path) converts with \(forbidden) itself")
            }
        }
    }
}
