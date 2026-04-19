import XCTest
@testable import esc_chatmail

final class InitialSyncOrchestratorTests: XCTestCase {
    func testCompletionDisposition_warnedInitialSyncStillAdvancesHistoryId() {
        let disposition = InitialSyncOrchestrator.completionDisposition(
            hadInitialFailures: true,
            permanentlyFailedCount: 1
        )

        XCTAssertEqual(
            disposition,
            InitialSyncCompletionDisposition(
                shouldAdvanceHistoryId: true,
                hadWarnings: true
            )
        )
    }

    func testCompletionDisposition_recoveredFailuresClearWarningsButKeepHistoryAdvance() {
        let disposition = InitialSyncOrchestrator.completionDisposition(
            hadInitialFailures: true,
            permanentlyFailedCount: 0
        )

        XCTAssertEqual(
            disposition,
            InitialSyncCompletionDisposition(
                shouldAdvanceHistoryId: true,
                hadWarnings: false
            )
        )
    }
}
