import XCTest
@testable import esc_chatmail

final class InitialSyncOrchestratorTests: XCTestCase {
    func testCompletionDisposition_warnedInitialSyncKeepsHistoryIdUnset() {
        let disposition = InitialSyncOrchestrator.completionDisposition(
            hadInitialFailures: true,
            permanentlyFailedCount: 1
        )

        XCTAssertEqual(
            disposition,
            InitialSyncCompletionDisposition(
                shouldAdvanceHistoryId: false,
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
