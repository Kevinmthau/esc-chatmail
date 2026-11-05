import XCTest
@testable import esc_chatmail

/// A full disk used to restart foreground sync every 60 s, each run re-fetching the whole
/// uncommitted backlog. `SyncStorageBackoff` refuses runs the disk cannot hold and spaces out
/// the ones that started anyway and failed.
final class SyncStorageBackoffTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)
    private let threshold = StoreVolumeFreeSpace.lowStorageThresholdBytes
    private let plenty: Int64 = 5 * 1024 * 1024 * 1024

    /// Revert-check: fails if `SyncStorageBackoff.delay(afterConsecutiveFailures:)` stops doubling
    /// or loses its 30-minute cap.
    func testDelay_doublesFromOneMinuteAndCapsAtThirty() {
        XCTAssertEqual(SyncStorageBackoff.delay(afterConsecutiveFailures: 0), 0)
        XCTAssertEqual(
            (1...8).map { SyncStorageBackoff.delay(afterConsecutiveFailures: $0) },
            [60, 120, 240, 480, 960, 1_800, 1_800, 1_800]
        )
        XCTAssertEqual(SyncStorageBackoff.delay(afterConsecutiveFailures: Int.max), 1_800)
    }

    /// Revert-check: fails if `admitsRun` drops its threshold check.
    func testAdmitsRun_refusesBelowTheThresholdAndAdmitsAnUnknownReading() {
        let backoff = SyncStorageBackoff()
        XCTAssertFalse(backoff.admitsRun(now: start, availableBytes: threshold - 1))
        XCTAssertTrue(backoff.admitsRun(now: start, availableBytes: threshold))
        XCTAssertTrue(backoff.admitsRun(now: start, availableBytes: nil))
    }

    /// The reading said there was room and the run still hit a full disk, so the reading
    /// cannot be trusted: wait out the window rather than refetching every minute.
    /// Revert-check: fails if `admitsRun` ignores `retryNotBefore`.
    func testAdmitsRun_refusesInsideTheWindowAndAdmitsAfterIt() {
        var backoff = SyncStorageBackoff()
        backoff.recordInsufficientStorage(now: start, availableBytes: plenty)

        XCTAssertFalse(backoff.admitsRun(now: start.addingTimeInterval(59), availableBytes: plenty))
        XCTAssertEqual(backoff.nextAdmissionDate(now: start), start.addingTimeInterval(60))
        XCTAssertTrue(backoff.admitsRun(now: start.addingTimeInterval(60), availableBytes: plenty))
        XCTAssertNil(backoff.nextAdmissionDate(now: start.addingTimeInterval(60)))

        backoff.recordInsufficientStorage(now: start.addingTimeInterval(60), availableBytes: plenty)
        XCTAssertFalse(backoff.admitsRun(now: start.addingTimeInterval(179), availableBytes: plenty))
        XCTAssertTrue(backoff.admitsRun(now: start.addingTimeInterval(180), availableBytes: plenty))
    }

    /// The user cleared space: retry at once instead of making them wait up to 30 minutes.
    /// Revert-check: fails if `admitsRun` drops the `availableBytesAtFailure + threshold` check.
    func testAdmitsRun_freedSpaceEndsTheWindowEarly() {
        var backoff = SyncStorageBackoff()
        let atFailure: Int64 = 300 * 1024 * 1024
        backoff.recordInsufficientStorage(now: start, availableBytes: atFailure)

        let soon = start.addingTimeInterval(10)
        XCTAssertFalse(backoff.admitsRun(now: soon, availableBytes: atFailure + threshold - 1))
        XCTAssertTrue(backoff.admitsRun(now: soon, availableBytes: atFailure + threshold))
        XCTAssertFalse(backoff.admitsRun(now: soon, availableBytes: nil))
    }

    /// Revert-check: fails if `recordSuccessfulRun` leaves the failure count in place.
    func testRecordSuccessfulRun_startsTheBackoffOver() {
        var backoff = SyncStorageBackoff()
        backoff.recordInsufficientStorage(now: start, availableBytes: plenty)
        backoff.recordInsufficientStorage(now: start, availableBytes: plenty)
        XCTAssertEqual(backoff.consecutiveFailures, 2)

        backoff.recordSuccessfulRun()
        XCTAssertEqual(backoff, SyncStorageBackoff())
        backoff.recordInsufficientStorage(now: start, availableBytes: plenty)
        XCTAssertEqual(backoff.nextAdmissionDate(now: start), start.addingTimeInterval(60))
    }
}
