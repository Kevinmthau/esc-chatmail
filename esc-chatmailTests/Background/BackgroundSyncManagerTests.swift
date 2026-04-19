import XCTest
@testable import esc_chatmail

final class BackgroundSyncManagerTests: XCTestCase {
    func testCompletionDisposition_truncationStoresContinuationAndSchedulesCatchUpRetry() {
        let continuationState = BackgroundSyncContinuationState.history(
            startHistoryId: "history-100",
            pageToken: "page-2"
        )
        let disposition = BackgroundSyncManager.completionDisposition(
            catchUpState: continuationState,
            hadFetchFailures: false,
            latestHistoryId: "history-123"
        )

        XCTAssertEqual(
            disposition,
            BackgroundSyncCompletionDisposition(
                historyIdToStore: nil,
                continuationState: continuationState,
                retryAction: .catchUp,
                shouldResetRetryState: false
            )
        )
    }

    func testCompletionDisposition_failuresUseFailureBackoff() {
        let disposition = BackgroundSyncManager.completionDisposition(
            hadFetchFailures: true,
            latestHistoryId: "history-123"
        )

        XCTAssertEqual(
            disposition,
            BackgroundSyncCompletionDisposition(
                historyIdToStore: nil,
                continuationState: nil,
                retryAction: .failureBackoff,
                shouldResetRetryState: false
            )
        )
    }

    func testCompletionDisposition_successAdvancesHistoryIdAndResetsRetryState() {
        let disposition = BackgroundSyncManager.completionDisposition(
            hadFetchFailures: false,
            latestHistoryId: "history-123"
        )

        XCTAssertEqual(
            disposition,
            BackgroundSyncCompletionDisposition(
                historyIdToStore: "history-123",
                continuationState: nil,
                retryAction: .none,
                shouldResetRetryState: true
            )
        )
    }

    func testHistoryContinuationCompatibility_requiresMatchingAccountAndCursor() {
        let continuationState = BackgroundSyncContinuationState.history(
            startHistoryId: "history-100",
            pageToken: "page-2",
            accountEmail: "user@example.com"
        )

        XCTAssertTrue(
            continuationState.isCompatible(
                storedHistoryId: "history-100",
                currentAccountEmail: "user@example.com"
            )
        )
        XCTAssertFalse(
            continuationState.isCompatible(
                storedHistoryId: "history-101",
                currentAccountEmail: "user@example.com"
            )
        )
        XCTAssertFalse(
            continuationState.isCompatible(
                storedHistoryId: "history-100",
                currentAccountEmail: "other@example.com"
            )
        )
    }

    func testPartialContinuationCompatibility_requiresSameAccountAndNoStoredCursor() {
        let continuationState = BackgroundSyncContinuationState.partial(
            query: "after:123 -label:spam",
            pageToken: "page-2",
            maxResults: 50,
            accountEmail: "user@example.com"
        )

        XCTAssertTrue(
            continuationState.isCompatible(
                storedHistoryId: nil,
                currentAccountEmail: "user@example.com"
            )
        )
        XCTAssertFalse(
            continuationState.isCompatible(
                storedHistoryId: "history-123",
                currentAccountEmail: "user@example.com"
            )
        )
        XCTAssertFalse(
            continuationState.isCompatible(
                storedHistoryId: nil,
                currentAccountEmail: "other@example.com"
            )
        )
    }

    func testContinuationCompatibility_rejectsLegacyUnscopedState() {
        let continuationState = BackgroundSyncContinuationState.partial(
            query: "after:123 -label:spam",
            pageToken: "page-2",
            maxResults: 50
        )

        XCTAssertFalse(
            continuationState.isCompatible(
                storedHistoryId: nil,
                currentAccountEmail: "user@example.com"
            )
        )
    }
}
