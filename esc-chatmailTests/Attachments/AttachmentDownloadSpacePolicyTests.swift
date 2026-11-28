import XCTest
@testable import esc_chatmail

/// The free-space floor a download must leave (`AttachmentDownloadSpacePolicy`).
final class AttachmentDownloadSpacePolicyTests: XCTestCase {
    func testFloor_isSyncsAdmissionThreshold() {
        XCTAssertEqual(AttachmentDownloadSpacePolicy.floorBytes, StoreVolumeFreeSpace.lowStorageThresholdBytes)
    }

    // Revert-check: subtracting `needed` in `AttachmentDownloadSpacePolicy.admitsDownload`.
    // Compare the free space with the floor alone and a download that would take the disk
    // below it is admitted.
    func testAdmitsDownload_exactlyAtTheFloorAfterTheDownload_isAdmitted_oneByteLessIsNot() {
        let floor = AttachmentDownloadSpacePolicy.floorBytes
        XCTAssertTrue(AttachmentDownloadSpacePolicy.admitsDownload(byteSize: 10_000, availableBytes: floor + 10_000))
        XCTAssertFalse(AttachmentDownloadSpacePolicy.admitsDownload(byteSize: 10_000, availableBytes: floor + 9_999))
    }

    func testAdmitsDownload_anUnknownSize_needsOnlyTheFloor() {
        let floor = AttachmentDownloadSpacePolicy.floorBytes
        XCTAssertTrue(AttachmentDownloadSpacePolicy.admitsDownload(byteSize: 0, availableBytes: floor))
        XCTAssertTrue(AttachmentDownloadSpacePolicy.admitsDownload(byteSize: -1, availableBytes: floor))
        XCTAssertFalse(AttachmentDownloadSpacePolicy.admitsDownload(byteSize: 0, availableBytes: floor - 1))
    }

    func testAdmitsDownload_anUnreadableVolume_isAdmitted() {
        XCTAssertTrue(AttachmentDownloadSpacePolicy.admitsDownload(byteSize: .max, availableBytes: nil))
    }

    func testAdmitsDownload_aSizeLargerThanTheVolume_isRefusedWithoutOverflow() {
        XCTAssertFalse(AttachmentDownloadSpacePolicy.admitsDownload(byteSize: .max, availableBytes: 0))
        XCTAssertFalse(AttachmentDownloadSpacePolicy.admitsDownload(byteSize: .max, availableBytes: .max - 1))
    }
}
