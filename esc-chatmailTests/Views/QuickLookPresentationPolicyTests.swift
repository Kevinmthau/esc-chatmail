import XCTest
@testable import esc_chatmail

/// `AttachmentGridView` clears its Quick Look state only for the presentation a
/// run or dismissal belongs to, so a tap that replaced it keeps its own.
///
/// HONEST SCOPE: `AttachmentGridView`'s `.task(id:)` wiring that feeds these the
/// run's outcome and the current state is not exercised here.
final class QuickLookPresentationPolicyTests: XCTestCase {
    private let attempted = UUID()
    private let newer = UUID()

    /// Revert-check: removing `current == attempted` from
    /// `QuickLookPresentationPolicy.shouldClearAfterPresentAttempt` makes this fail.
    func testShouldClearAfterPresentAttempt_runCancelledByNewerTap_keepsState() {
        XCTAssertFalse(QuickLookPresentationPolicy.shouldClearAfterPresentAttempt(
            attempted, outcome: .cancelled, current: newer
        ))
    }

    /// A run cancelled because the view disappeared must not leave its presentation
    /// behind, or the `.task(id:)` restarts on reappear and opens Quick Look unprompted.
    ///
    /// Revert-check: exempting `.cancelled` in
    /// `QuickLookPresentationPolicy.shouldClearAfterPresentAttempt` (the earlier
    /// `!wasCancelled` term) makes this fail.
    func testShouldClearAfterPresentAttempt_runCancelledWhileOwningState_clearsState() {
        XCTAssertTrue(QuickLookPresentationPolicy.shouldClearAfterPresentAttempt(
            attempted, outcome: .cancelled, current: attempted
        ))
    }

    func testShouldClearAfterPresentAttempt_noPresenterForCurrentRun_clearsState() {
        XCTAssertTrue(QuickLookPresentationPolicy.shouldClearAfterPresentAttempt(
            attempted, outcome: .noPresenter, current: attempted
        ))
    }

    func testShouldClearAfterPresentAttempt_presented_keepsState() {
        XCTAssertFalse(QuickLookPresentationPolicy.shouldClearAfterPresentAttempt(
            attempted, outcome: .presented, current: attempted
        ))
    }

    /// Revert-check: replacing `QuickLookPresentationPolicy.shouldClearOnDismiss`'s
    /// `current == dismissed` with `true` makes this fail.
    func testShouldClearOnDismiss_stateReplacedByNewerTap_keepsState() {
        XCTAssertFalse(QuickLookPresentationPolicy.shouldClearOnDismiss(of: attempted, current: newer))
    }

    func testShouldClearOnDismiss_dismissedCurrentPresentation_clearsState() {
        XCTAssertTrue(QuickLookPresentationPolicy.shouldClearOnDismiss(of: attempted, current: attempted))
    }
}
