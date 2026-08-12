import XCTest
@testable import esc_chatmail

final class AuthRestoreReopenPolicyTests: XCTestCase {
    // Revert-check: fails if AuthRestoreReopenPolicy.restoreDispositionAfterReopen(_:)
    // changes any mapping, and fails to compile-then-fail loudly if a new
    // AccountWorkReopenOutcome case is added without an explicit decision here.
    // The restore path stages live credentials before reopening, so each cause
    // needs its own answer to "who owns these credentials now".
    func testRestoreDispositionIsDecidedForEveryReopenOutcome() {
        let expected: [AccountWorkReopenOutcome: AuthRestoreReopenPolicy.RestoreDisposition] = [
            .reopened: .publishSession,
            .transientFailure: .retryKeepingCredentials,
            .latchedRefusal: .discardCredentials,
            .supersededByAccountRemoval: .retryKeepingCredentials
        ]

        XCTAssertEqual(
            Set(expected.keys),
            Set(AccountWorkReopenOutcome.allCases),
            "A new reopen outcome must make an explicit credential-disposition decision"
        )
        for (outcome, disposition) in expected {
            XCTAssertEqual(
                AuthRestoreReopenPolicy.restoreDispositionAfterReopen(outcome),
                disposition,
                "outcome: \(outcome)"
            )
        }
    }

    // Revert-check: fails if restoreDispositionAfterReopen(_:) maps
    // .transientFailure or .supersededByAccountRemoval to .discardCredentials —
    // the exact over-reach a bare Bool return invited. A thrown reopen step is
    // retryable with these same credentials (the bootstrap retries the restore),
    // and a superseding sign-out already performs its own credential cleanup.
    func testTransientAndSupersededReopenFailuresKeepRestoredCredentials() {
        XCTAssertEqual(
            AuthRestoreReopenPolicy.restoreDispositionAfterReopen(.transientFailure),
            .retryKeepingCredentials
        )
        XCTAssertEqual(
            AuthRestoreReopenPolicy.restoreDispositionAfterReopen(.supersededByAccountRemoval),
            .retryKeepingCredentials
        )
        for outcome in AccountWorkReopenOutcome.allCases where outcome != .latchedRefusal {
            XCTAssertNotEqual(
                AuthRestoreReopenPolicy.restoreDispositionAfterReopen(outcome),
                .discardCredentials,
                "Only a latched refusal makes this restore the sole owner of the staged credentials (outcome: \(outcome))"
            )
        }
    }
}
