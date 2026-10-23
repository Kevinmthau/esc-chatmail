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
