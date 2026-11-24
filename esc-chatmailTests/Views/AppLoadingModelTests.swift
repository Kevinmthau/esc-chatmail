import XCTest
import CoreData
@testable import esc_chatmail

@MainActor
final class AppLoadingModelTests: XCTestCase {
    private let threshold = AppLoadingPolicy.mailboxResetFailureThreshold
    private let keptStoreFailure = CoreDataError.storeLoadFailed(
        PersistentStoreLoadError.unavailable(
            NSError(domain: NSCocoaErrorDomain, code: NSPersistentStoreTypeMismatchError)
        )
    )
    private let fullDiskFailure = CoreDataError.storeLoadFailed(
        PersistentStoreLoadError.insufficientStorage(
            NSError(domain: NSCocoaErrorDomain, code: NSFileWriteOutOfSpaceError)
        )
    )

    private let newerBuildFailure = CoreDataError.storeLoadFailed(
        PersistentStoreLoadError.storeFromNewerVersion(
            NSError(domain: NSCocoaErrorDomain, code: NSPersistentStoreIncompatibleVersionHashError)
        )
    )
    private let failedMigration = CoreDataError.storeLoadFailed(
        PersistentStoreLoadError.migrationFailed(
            NSError(domain: NSCocoaErrorDomain, code: NSMigrationError)
        )
    )

    /// Kevin, 2026-11-24: a store a newer MushMail saved is never offered a
    /// reset, however often it fails: the foreground retry loop alone fails it
    /// past the threshold in about 15 seconds.
    ///
    /// Revert-check: `AppLoadingPolicy.offersResetPastThreshold` answering true
    /// for `.storeFromNewerVersion` (it then counts toward the threshold), with
    /// the `.storeFromNewerVersion` notice in `storeLoadFailureNotice` falling
    /// through to the migration-failure case.
    func testShowStoreLoadFailure_storeFromNewerVersion_neverOffersResetAndAsksToUpdate() {
        let harness = Harness()

        for _ in 0..<(threshold * 4) {
            harness.model.showStoreLoadFailure(newerBuildFailure)
            XCTAssertEqual(harness.model.storeLoadFailure?.offersMailboxReset, false)
        }

        XCTAssertEqual(harness.model.storeLoadFailure?.title, "Update MushMail")
    }

    /// A streak of a store that could not be opened, which a reset is offered
    /// for, cannot carry over to a newer build's store: the newer-build failure
    /// ends it, and the next failure of the first kind starts again from one.
    ///
    /// Revert-check: the `offersResetPastThreshold` guard in
    /// `AppLoadingPolicy.resetEligibleFailureCount`.
    func testShowStoreLoadFailure_newerBuildFailureMidStreak_endsStreak() {
        let harness = Harness()
        for _ in 0..<(threshold - 1) {
            harness.model.showStoreLoadFailure(keptStoreFailure)
        }

        harness.model.showStoreLoadFailure(newerBuildFailure)
        harness.model.showStoreLoadFailure(keptStoreFailure)

        XCTAssertEqual(harness.model.storeLoadFailure?.offersMailboxReset, false)
    }

    /// Kevin, 2026-11-24: a migration that fails on the user's data is offered
    /// the confirmed reset once retrying has not helped, and not before.
    ///
    /// Revert-check: `AppLoadingPolicy.offersResetPastThreshold` answering
    /// false for `.migrationFailed`.
    func testShowStoreLoadFailure_failedMigration_offersResetAtThreshold() {
        let harness = Harness()

        for _ in 0..<(threshold - 1) {
            harness.model.showStoreLoadFailure(failedMigration)
        }
        XCTAssertEqual(harness.model.storeLoadFailure?.offersMailboxReset, false)

        harness.model.showStoreLoadFailure(failedMigration)
        XCTAssertEqual(harness.model.storeLoadFailure?.offersMailboxReset, true)
    }

    /// The launch loop's timed retries do not reload a store whose migration
    /// failed; the retry the user asks for, and the one after a reset, must.
    ///
    /// Revert-check: the `permitReloadAfterDeterministicFailure()` call in
    /// `AppLoadingModel.retry`.
    func testRetryAndReset_permitTheReloadOfAFailedMigration() {
        let harness = Harness()
        harness.model.showStoreLoadFailure(failedMigration)

        harness.model.retry()
        XCTAssertEqual(harness.reloadPermitCount, 1)

        for _ in 0..<threshold {
            harness.model.showStoreLoadFailure(failedMigration)
        }
        harness.model.resetMailbox()
        XCTAssertEqual(harness.resetCallCount, 1)
        XCTAssertEqual(harness.reloadPermitCount, 2, "The empty store must be loaded after the reset")
    }

    /// Revert-check: making `AppLoadingModel.showStoreLoadFailure` pass a
    /// `previousCount` of 0 never reaches the threshold and fails this.
    func testShowStoreLoadFailure_repeatedKeptStoreFailures_offerResetAtThreshold() {
        let harness = Harness()

        for _ in 0..<(threshold - 1) {
            harness.model.showStoreLoadFailure(keptStoreFailure)
        }
        XCTAssertEqual(harness.model.storeLoadFailure?.offersMailboxReset, false)

        harness.model.showStoreLoadFailure(keptStoreFailure)
        XCTAssertEqual(harness.model.storeLoadFailure?.offersMailboxReset, true)
    }

    func testShowStoreLoadFailure_fullDiskMidStreak_restartsCount() {
        let harness = Harness()
        for _ in 0..<(threshold - 1) {
            harness.model.showStoreLoadFailure(keptStoreFailure)
        }

        harness.model.showStoreLoadFailure(fullDiskFailure)
        XCTAssertEqual(harness.model.storeLoadFailure?.offersMailboxReset, false)
        harness.model.showStoreLoadFailure(keptStoreFailure)

        XCTAssertEqual(harness.model.storeLoadFailure?.offersMailboxReset, false)
    }

    /// Revert-check: passing `true` for `isProtectedDataAvailable` in
    /// `AppLoadingModel.showStoreLoadFailure` offers the reset here.
    func testShowStoreLoadFailure_failuresWhileProtectedDataUnavailable_doNotCount() {
        let harness = Harness()
        harness.isProtectedDataAvailable = false

        for _ in 0..<(threshold * 2) {
            harness.model.showStoreLoadFailure(keptStoreFailure)
        }

        XCTAssertEqual(harness.model.storeLoadFailure?.offersMailboxReset, false)
    }

    /// The stack refuses to reset without a free-space reading, so the
    /// screen must not offer a button that cannot work, and those failures
    /// must not earn the offer for when a reading returns.
    ///
    /// Revert-check: passing `true` for `isFreeSpaceKnown` to
    /// `AppLoadingPolicy.resetEligibleFailureCount` in
    /// `AppLoadingModel.showStoreLoadFailure` offers the reset on the first
    /// failure with a reading; passing it to `storeLoadFailureNotice` too
    /// also offers it during the loop.
    func testShowStoreLoadFailure_failuresWithFreeSpaceUnknown_doNotCount() {
        let harness = Harness()
        harness.availableCapacityBytes = nil

        for _ in 0..<(threshold * 2) {
            harness.model.showStoreLoadFailure(keptStoreFailure)
        }

        XCTAssertEqual(harness.model.storeLoadFailure?.offersMailboxReset, false)
        XCTAssertEqual(harness.model.storeLoadFailure?.title, "Can't Open Your Mail")

        harness.availableCapacityBytes = 50 * 1024 * 1024 * 1024
        harness.model.showStoreLoadFailure(keptStoreFailure)

        XCTAssertEqual(harness.model.storeLoadFailure?.offersMailboxReset, false)
    }

    /// An offer earned with readings must not survive a failure whose free
    /// space could not be measured: the stack would refuse the reset, and
    /// confirming the data loss would only retry into the same offer. The
    /// streak survives, so the offer returns with the next reading.
    ///
    /// Revert-check: passing `true` for `isFreeSpaceKnown` to
    /// `AppLoadingPolicy.storeLoadFailureNotice` in
    /// `AppLoadingModel.showStoreLoadFailure` keeps the offer and resets here.
    func testShowStoreLoadFailure_freeSpaceUnknownAfterOffer_withholdsResetUntilReadingReturns() {
        let harness = Harness()
        harness.offerReset()

        harness.availableCapacityBytes = nil
        harness.model.showStoreLoadFailure(keptStoreFailure)
        harness.model.resetMailbox()

        XCTAssertEqual(harness.model.storeLoadFailure?.offersMailboxReset, false)
        XCTAssertEqual(harness.model.storeLoadFailure?.title, "Can't Open Your Mail")
        XCTAssertEqual(harness.resetCallCount, 0)

        harness.availableCapacityBytes = 50 * 1024 * 1024 * 1024
        harness.model.showStoreLoadFailure(keptStoreFailure)

        XCTAssertEqual(harness.model.storeLoadFailure?.offersMailboxReset, true)
    }

    /// Revert-check: deleting the count reset from
    /// `AppLoadingModel.clearStoreLoadFailure` offers the reset on the first
    /// failure after a successful load.
    func testClearStoreLoadFailure_afterSuccessfulLoad_restartsCount() {
        let harness = Harness()
        for _ in 0..<threshold {
            harness.model.showStoreLoadFailure(keptStoreFailure)
        }

        harness.model.clearStoreLoadFailure()
        harness.model.showStoreLoadFailure(keptStoreFailure)

        XCTAssertEqual(harness.model.storeLoadFailure?.offersMailboxReset, false)
    }

    func testResetMailbox_storeRemoved_returnsToSpinnerAndRetries() async {
        let harness = Harness()
        harness.resetOutcome = .removed
        harness.offerReset()

        harness.model.resetMailbox()

        XCTAssertEqual(harness.resetCallCount, 1)
        XCTAssertNil(harness.model.storeLoadFailure)
        await waitUntil { await harness.retryRequests.count == 1 }
    }

    /// The empty store has to earn the offer again.
    ///
    /// Revert-check: deleting the count reset from the `.removed` case of
    /// `AppLoadingModel.resetMailbox` offers the reset on the next failure.
    func testResetMailbox_storeRemoved_restartsCount() {
        let harness = Harness()
        harness.resetOutcome = .removed
        harness.offerReset()

        harness.model.resetMailbox()
        harness.model.showStoreLoadFailure(keptStoreFailure)

        XCTAssertEqual(harness.model.storeLoadFailure?.offersMailboxReset, false)
    }

    /// Revert-check: routing `.failed` in `AppLoadingModel.resetMailbox` to
    /// `retry()` fails both assertions.
    func testResetMailbox_backupFailed_saysNothingWasDeletedWithoutRetrying() async {
        let harness = Harness()
        harness.resetOutcome = .failed
        harness.offerReset()

        harness.model.resetMailbox()

        XCTAssertEqual(harness.model.storeLoadFailure, AppLoadingPolicy.mailboxResetFailedNotice)
        try? await Task.sleep(nanoseconds: 100_000_000)
        let retryCount = await harness.retryRequests.count
        XCTAssertEqual(retryCount, 0)
    }

    func testResetMailbox_nothingToReset_retries() async {
        let harness = Harness()
        harness.resetOutcome = .notResettable
        harness.offerReset()

        harness.model.resetMailbox()

        XCTAssertNil(harness.model.storeLoadFailure)
        await waitUntil { await harness.retryRequests.count == 1 }
    }

    /// A failure of another kind can replace the notice while the
    /// confirmation is up; confirming then must not reset.
    ///
    /// Revert-check: deleting the `offersMailboxReset` guard from
    /// `AppLoadingModel.resetMailbox` resets the store here.
    func testResetMailbox_noticeNoLongerOffersReset_doesNothing() {
        let harness = Harness()
        harness.offerReset()
        harness.model.showStoreLoadFailure(fullDiskFailure)

        harness.model.resetMailbox()

        XCTAssertEqual(harness.resetCallCount, 0)
        XCTAssertEqual(harness.model.storeLoadFailure?.title, "Not Enough Storage")
    }

    // MARK: - Helpers

    private final class Harness {
        let retryRequests = RetryRequestCounter()
        var resetOutcome: CoreDataStack.StoreResetOutcome = .removed
        var resetCallCount = 0
        var reloadPermitCount = 0
        var isProtectedDataAvailable = true
        var availableCapacityBytes: Int64? = 50 * 1024 * 1024 * 1024
        private(set) var model: AppLoadingModel!

        @MainActor
        init() {
            let retryRequests = self.retryRequests
            model = AppLoadingModel(
                requestRetry: { await retryRequests.increment() },
                resetStore: { [unowned self] in
                    resetCallCount += 1
                    return resetOutcome
                },
                permitReloadAfterDeterministicFailure: { [unowned self] in
                    reloadPermitCount += 1
                },
                availableCapacityBytes: { [unowned self] in availableCapacityBytes },
                isProtectedDataAvailable: { [unowned self] in isProtectedDataAvailable }
            )
        }

        @MainActor
        func offerReset() {
            for _ in 0..<AppLoadingPolicy.mailboxResetFailureThreshold {
                model.showStoreLoadFailure(
                    CoreDataError.storeLoadFailed(
                        PersistentStoreLoadError.unavailable(NSError(domain: NSCocoaErrorDomain, code: NSFileReadUnknownError))
                    )
                )
            }
            XCTAssertEqual(model.storeLoadFailure?.offersMailboxReset, true, "Setup must reach the reset offer")
        }
    }

    private func waitUntil(
        timeout: TimeInterval = 5.0,
        pollIntervalNanoseconds: UInt64 = 10_000_000,
        file: StaticString = #filePath,
        line: UInt = #line,
        condition: () async -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !(await condition()) {
            guard Date() < deadline else {
                XCTFail("Timed out waiting for condition", file: file, line: line)
                return
            }
            try? await Task.sleep(nanoseconds: pollIntervalNanoseconds)
        }
    }
}

private actor RetryRequestCounter {
    private(set) var count = 0

    func increment() {
        count += 1
    }
}
