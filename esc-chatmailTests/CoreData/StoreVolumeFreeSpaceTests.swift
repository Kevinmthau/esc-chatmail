import XCTest
@testable import esc_chatmail

final class StoreVolumeFreeSpaceTests: XCTestCase {
    private let gigabyte: Int64 = 1024 * 1024 * 1024

    /// Purgeable space counts toward important-usage capacity but SQLite
    /// cannot write into it, so a device with gigabytes purgeable and nothing
    /// free is full as far as the store is concerned.
    ///
    /// Revert-check: taking the larger reading (`max`) in
    /// `StoreVolumeFreeSpace.usableBytes` fails this.
    func testUsableBytes_spaceOnlyPurgeable_reportsActualFreeSpace() {
        let usable = StoreVolumeFreeSpace.usableBytes(
            availableCapacity: 10 * 1024 * 1024,
            importantUsageCapacity: 5 * gigabyte
        )

        XCTAssertEqual(usable, 10 * 1024 * 1024)
        XCTAssertFalse(StoreVolumeFreeSpace.hasRoomForStoreReset(availableBytes: usable))
    }

    func testUsableBytes_oneReadingMissing_usesTheOther() {
        XCTAssertEqual(StoreVolumeFreeSpace.usableBytes(availableCapacity: gigabyte, importantUsageCapacity: nil), gigabyte)
        XCTAssertEqual(StoreVolumeFreeSpace.usableBytes(availableCapacity: nil, importantUsageCapacity: gigabyte), gigabyte)
        XCTAssertNil(StoreVolumeFreeSpace.usableBytes(availableCapacity: nil, importantUsageCapacity: nil))
    }

    /// A reset frees nothing on a full disk, so it never assumes room it
    /// could not measure.
    ///
    /// Revert-check: returning true for a nil reading in
    /// `StoreVolumeFreeSpace.hasRoomForStoreReset` fails this.
    func testHasRoomForStoreReset_unknownFreeSpace_isFalse() {
        XCTAssertFalse(StoreVolumeFreeSpace.hasRoomForStoreReset(availableBytes: nil))
    }

    func testHasRoomForStoreReset_threshold_isTheFirstByteWithRoom() {
        let threshold = StoreVolumeFreeSpace.lowStorageThresholdBytes

        XCTAssertFalse(StoreVolumeFreeSpace.hasRoomForStoreReset(availableBytes: threshold - 1))
        XCTAssertTrue(StoreVolumeFreeSpace.hasRoomForStoreReset(availableBytes: threshold))
    }

    /// The probe reads the real volume; the simulator always has one.
    func testAvailableBytes_realVolume_returnsReading() {
        XCTAssertNotNil(StoreVolumeFreeSpace.availableBytes())
    }
}
