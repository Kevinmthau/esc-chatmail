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
        XCTAssertTrue(backoff.admitsRun(now: start.addingTimeInterval(60), availableBytes: plenty))

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

    /// Revert-check: fails if `recordSuccessfulRun(storedMessageCount:)` leaves the failure count
    /// in place.
    func testRecordSuccessfulRun_thatStoredMail_startsTheBackoffOver() {
        var backoff = SyncStorageBackoff()
        backoff.recordInsufficientStorage(now: start, availableBytes: plenty)
        backoff.recordInsufficientStorage(now: start, availableBytes: plenty)
        XCTAssertEqual(backoff.consecutiveFailures, 2)

        backoff.recordSuccessfulRun(storedMessageCount: 1)
        XCTAssertEqual(backoff, SyncStorageBackoff())
        backoff.recordInsufficientStorage(now: start, availableBytes: plenty)
        XCTAssertFalse(backoff.admitsRun(now: start.addingTimeInterval(59), availableBytes: plenty))
        XCTAssertTrue(backoff.admitsRun(now: start.addingTimeInterval(60), availableBytes: plenty))
    }

    /// A run that stored no mail (no new mail, a label-only slice) can succeed on a disk still too
    /// full for message bodies. Resetting on it held the backoff at its first minute while the
    /// disk stayed full.
    /// Revert-check: the `storedMessageCount > 0` guard in
    /// `SyncStorageBackoff.recordSuccessfulRun(storedMessageCount:)`.
    func testRecordSuccessfulRun_thatStoredNoMail_keepsTheBackoffGrowing() {
        var backoff = SyncStorageBackoff()
        backoff.recordInsufficientStorage(now: start, availableBytes: plenty)
        backoff.recordInsufficientStorage(now: start, availableBytes: plenty)

        backoff.recordSuccessfulRun(storedMessageCount: 0)
        XCTAssertEqual(backoff.consecutiveFailures, 2)

        let later = start.addingTimeInterval(600)
        backoff.recordInsufficientStorage(now: later, availableBytes: plenty)
        XCTAssertFalse(
            backoff.admitsRun(now: later.addingTimeInterval(239), availableBytes: plenty),
            "The third failure in a row waits four minutes"
        )
        XCTAssertTrue(backoff.admitsRun(now: later.addingTimeInterval(240), availableBytes: plenty))
    }

    /// The banner follows the backoff's evidence. A run with no new mail succeeds on a disk still
    /// too full for message bodies, and lifting the banner on it hid a full disk until the next
    /// real message raised it again.
    /// Revert-check: the `consecutiveFailures > 0` and freed-space checks in
    /// `SyncStorageBackoff.liftsInsufficientStorageBanner(availableBytes:threshold:)` (a run that
    /// stored nothing then lifts the banner over a still-full disk).
    func testLiftsInsufficientStorageBanner_afterAFullDiskStop_onlyOnStoredMailOrFreedSpace() {
        var backoff = SyncStorageBackoff()
        XCTAssertTrue(
            backoff.liftsInsufficientStorageBanner(availableBytes: plenty),
            "With no stop outstanding an admitted run lifts a refusal's banner"
        )
        backoff.recordInsufficientStorage(now: start, availableBytes: plenty)

        backoff.recordSuccessfulRun(storedMessageCount: 0)
        XCTAssertFalse(
            backoff.liftsInsufficientStorageBanner(availableBytes: plenty),
            "A reading above the threshold is what the stop happened on"
        )
        XCTAssertFalse(backoff.liftsInsufficientStorageBanner(availableBytes: plenty + threshold - 1))
        XCTAssertFalse(backoff.liftsInsufficientStorageBanner(availableBytes: nil))
        XCTAssertTrue(
            backoff.liftsInsufficientStorageBanner(availableBytes: plenty + threshold),
            "Space freed since the stop lifts it, as it ends the backoff window"
        )

        backoff.recordSuccessfulRun(storedMessageCount: 1)
        XCTAssertTrue(
            backoff.liftsInsufficientStorageBanner(availableBytes: plenty),
            "Stored mail proves the disk takes writes"
        )
    }
}
