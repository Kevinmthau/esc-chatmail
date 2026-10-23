import XCTest
import CoreData
@testable import esc_chatmail

final class AppLoadingPolicyTests: XCTestCase {
    private let plentyOfSpace: Int64 = 50 * 1024 * 1024 * 1024
    private let threshold = AppLoadingPolicy.mailboxResetFailureThreshold

    func testStoreLoadFailureKind_insufficientStorage_asksToFreeSpace() {
        let error = CoreDataError.storeLoadFailed(
            PersistentStoreLoadError.insufficientStorage(
                NSError(domain: NSCocoaErrorDomain, code: NSFileWriteOutOfSpaceError)
            )
        )

        let kind = AppLoadingPolicy.storeLoadFailureKind(for: error, availableCapacityBytes: plentyOfSpace)
        let notice = AppLoadingPolicy.storeLoadFailureNotice(for: kind, resetEligibleFailureCount: 0)

        XCTAssertEqual(kind, .insufficientStorage)
        XCTAssertEqual(notice.title, "Not Enough Storage")
    }

    /// At 0 bytes free SQLite reports CANTOPEN, not FULL.
    ///
    /// Revert-check: dropping `isLowOnStorage` from
    /// `AppLoadingPolicy.storeLoadFailureKind` fails this.
    func testStoreLoadFailureKind_ambiguousErrorOnNearlyFullDevice_asksToFreeSpace() {
        let error = CoreDataError.storeLoadFailed(
            PersistentStoreLoadError.unavailable(
                NSError(
                    domain: NSCocoaErrorDomain,
                    code: NSFileReadUnknownError,
                    userInfo: [NSSQLiteErrorDomain: NSNumber(value: 14)]
                )
            )
        )

        let kind = AppLoadingPolicy.storeLoadFailureKind(for: error, availableCapacityBytes: 1024)

        XCTAssertEqual(kind, .insufficientStorage)
    }

    func testStoreLoadFailureKind_keptStoreWithSpace_isStoreUnavailable() {
        let error = CoreDataError.storeLoadFailed(
            PersistentStoreLoadError.unavailable(NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoPermissionError))
        )

        let withSpace = AppLoadingPolicy.storeLoadFailureKind(for: error, availableCapacityBytes: plentyOfSpace)
        let capacityUnknown = AppLoadingPolicy.storeLoadFailureKind(for: error, availableCapacityBytes: nil)
        let notice = AppLoadingPolicy.storeLoadFailureNotice(for: withSpace, resetEligibleFailureCount: 1)

        XCTAssertEqual(withSpace, .storeUnavailable)
        XCTAssertEqual(capacityUnknown, .storeUnavailable)
        XCTAssertEqual(notice.title, "Can't Open Your Mail")
        XCTAssertFalse(notice.offersMailboxReset)
    }

    /// Only a latched, kept store can be reset by the stack, so an error of
    /// any other shape must not count toward the offer.
    func testStoreLoadFailureKind_errorThatIsNotAKeptStore_isOther() {
        let error = CoreDataError.storeLoadFailed(NSError(domain: "CoreData", code: -1))

        let kind = AppLoadingPolicy.storeLoadFailureKind(for: error, availableCapacityBytes: plentyOfSpace)

        XCTAssertEqual(kind, .other)
    }

    func testResetEligibleFailureCount_storeUnavailable_countsUp() {
        let count = AppLoadingPolicy.resetEligibleFailureCount(
            afterFailureOf: .storeUnavailable,
            previousCount: 2,
            isProtectedDataAvailable: true,
            isFreeSpaceKnown: true
        )

        XCTAssertEqual(count, 3)
    }

    /// Freeing space is the fix for a full device, so a storage failure
    /// ends the streak instead of edging toward a reset.
    ///
    /// Revert-check: counting every kind in
    /// `AppLoadingPolicy.resetEligibleFailureCount` (dropping its
    /// `kind == .storeUnavailable` guard) fails this.
    func testResetEligibleFailureCount_storageOrOtherFailure_endsStreak() {
        for kind in [AppLoadingPolicy.StoreLoadFailureKind.insufficientStorage, .other] {
            let count = AppLoadingPolicy.resetEligibleFailureCount(
                afterFailureOf: kind,
                previousCount: threshold,
                isProtectedDataAvailable: true,
                isFreeSpaceKnown: true
            )

            XCTAssertEqual(count, 0, "\(kind)")
        }
    }

    /// A cold background launch before first unlock fails every attempt;
    /// those failures say nothing about the file.
    ///
    /// Revert-check: ignoring `isProtectedDataAvailable` in
    /// `AppLoadingPolicy.resetEligibleFailureCount` fails this.
    func testResetEligibleFailureCount_protectedDataUnavailable_neitherCountsNorEndsStreak() {
        let count = AppLoadingPolicy.resetEligibleFailureCount(
            afterFailureOf: .storeUnavailable,
            previousCount: 2,
            isProtectedDataAvailable: false,
            isFreeSpaceKnown: true
        )

        XCTAssertEqual(count, 2)
    }

    /// Without a free-space reading a full disk cannot be ruled out, and the
    /// stack refuses to reset, so the failure must not edge toward an offer.
    ///
    /// Revert-check: ignoring `isFreeSpaceKnown` in
    /// `AppLoadingPolicy.resetEligibleFailureCount` fails this.
    func testResetEligibleFailureCount_freeSpaceUnknown_neitherCountsNorEndsStreak() {
        let count = AppLoadingPolicy.resetEligibleFailureCount(
            afterFailureOf: .storeUnavailable,
            previousCount: 2,
            isProtectedDataAvailable: true,
            isFreeSpaceKnown: false
        )

        XCTAssertEqual(count, 2)
    }

    /// Revert-check: lowering the `where` clause in
    /// `AppLoadingPolicy.storeLoadFailureNotice` to any count fails the
    /// below-threshold assertion.
    func testStoreLoadFailureNotice_storeUnavailable_offersResetOnlyFromThreshold() {
        let below = AppLoadingPolicy.storeLoadFailureNotice(
            for: .storeUnavailable,
            resetEligibleFailureCount: threshold - 1
        )
        let atThreshold = AppLoadingPolicy.storeLoadFailureNotice(
            for: .storeUnavailable,
            resetEligibleFailureCount: threshold
        )

        XCTAssertFalse(below.offersMailboxReset)
        XCTAssertTrue(atThreshold.offersMailboxReset)
        XCTAssertEqual(atThreshold.title, "Can't Open Your Mail")
    }

    func testStoreLoadFailureNotice_storageOrOtherFailure_neverOffersReset() {
        for kind in [AppLoadingPolicy.StoreLoadFailureKind.insufficientStorage, .other] {
            let notice = AppLoadingPolicy.storeLoadFailureNotice(
                for: kind,
                resetEligibleFailureCount: threshold * 10
            )

            XCTAssertFalse(notice.offersMailboxReset, "\(kind)")
        }
    }

    /// The confirmation is the user's only warning of what a reset loses.
    func testMailboxResetConfirmation_namesUnsyncedChangesAndUnsentMessages() {
        let message = AppLoadingPolicy.mailboxResetConfirmation.message

        XCTAssertTrue(message.contains("haven't synced"), message)
        XCTAssertTrue(message.contains("haven't finished sending"), message)
    }

    @MainActor
    func testRetry_returnsToSpinnerAndRequestsRetry() async {
        let retryRequests = RetryRequestCounter()
        let model = AppLoadingModel(
            requestRetry: { await retryRequests.increment() },
            availableCapacityBytes: { nil }
        )
        model.showStoreLoadFailure(NSError(domain: NSCocoaErrorDomain, code: NSFileWriteOutOfSpaceError))
        XCTAssertEqual(model.storeLoadFailure?.title, "Not Enough Storage")

        model.retry()

        XCTAssertNil(model.storeLoadFailure)
        let deadline = Date().addingTimeInterval(5)
        while await retryRequests.count == 0, Date() < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        let count = await retryRequests.count
        XCTAssertEqual(count, 1)
    }
}

private actor RetryRequestCounter {
    private(set) var count = 0

    func increment() {
        count += 1
    }
}
