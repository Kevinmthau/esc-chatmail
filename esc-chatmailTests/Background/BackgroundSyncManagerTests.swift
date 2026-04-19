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
}
