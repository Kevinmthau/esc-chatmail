import XCTest
import CoreData
@testable import esc_chatmail

final class AppLoadingPolicyTests: XCTestCase {
    private let plentyOfSpace: Int64 = 50 * 1024 * 1024 * 1024

    func testStoreLoadFailureNotice_insufficientStorage_asksToFreeSpace() {
        let error = CoreDataError.storeLoadFailed(
            PersistentStoreLoadError.insufficientStorage(
                NSError(domain: NSCocoaErrorDomain, code: NSFileWriteOutOfSpaceError)
            )
        )

        let notice = AppLoadingPolicy.storeLoadFailureNotice(for: error, availableCapacityBytes: plentyOfSpace)

        XCTAssertEqual(notice.title, "Not Enough Storage")
    }

    /// At 0 bytes free SQLite reports CANTOPEN, not FULL.
    ///
    /// Revert-check: dropping `isLowOnStorage` from
    /// `AppLoadingPolicy.storeLoadFailureNotice` fails this.
    func testStoreLoadFailureNotice_ambiguousErrorOnNearlyFullDevice_asksToFreeSpace() {
        let error = CoreDataError.storeLoadFailed(
            PersistentStoreLoadError.unavailable(
                NSError(
                    domain: NSCocoaErrorDomain,
                    code: NSFileReadUnknownError,
                    userInfo: [NSSQLiteErrorDomain: NSNumber(value: 14)]
                )
            )
        )

        let notice = AppLoadingPolicy.storeLoadFailureNotice(for: error, availableCapacityBytes: 1024)

        XCTAssertEqual(notice.title, "Not Enough Storage")
    }

    func testStoreLoadFailureNotice_otherFailureWithSpace_offersRetry() {
        let error = CoreDataError.storeLoadFailed(
            PersistentStoreLoadError.unavailable(NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoPermissionError))
        )

        let withSpace = AppLoadingPolicy.storeLoadFailureNotice(for: error, availableCapacityBytes: plentyOfSpace)
        let capacityUnknown = AppLoadingPolicy.storeLoadFailureNotice(for: error, availableCapacityBytes: nil)

        XCTAssertEqual(withSpace.title, "Can't Open Your Mail")
        XCTAssertEqual(capacityUnknown, withSpace)
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
