import XCTest
@testable import esc_chatmail

/// `AttachmentGridView` clears its Quick Look state only for the presentation a
/// run or dismissal belongs to, so a tap that replaced it keeps its own.
///
/// HONEST SCOPE: `AttachmentGridView`'s `.task(id:)` wiring that feeds these the
/// run's `Task.isCancelled` and the current state is not exercised here.
final class QuickLookPresentationPolicyTests: XCTestCase {
    private let attempted = UUID()
    private let newer = UUID()

    /// Revert-check: removing `!wasCancelled` from
    /// `QuickLookPresentationPolicy.shouldClearAfterPresentAttempt` makes this fail.
    func testShouldClearAfterPresentAttempt_cancelledRun_keepsState() {
        XCTAssertFalse(QuickLookPresentationPolicy.shouldClearAfterPresentAttempt(
            attempted, didPresent: false, wasCancelled: true, current: attempted
        ))
    }

    /// Revert-check: removing `current == attempted` from
    /// `QuickLookPresentationPolicy.shouldClearAfterPresentAttempt` makes this fail.
    func testShouldClearAfterPresentAttempt_stateReplacedByNewerTap_keepsState() {
        XCTAssertFalse(QuickLookPresentationPolicy.shouldClearAfterPresentAttempt(
            attempted, didPresent: false, wasCancelled: false, current: newer
        ))
    }

    func testShouldClearAfterPresentAttempt_noPresenterForCurrentRun_clearsState() {
        XCTAssertTrue(QuickLookPresentationPolicy.shouldClearAfterPresentAttempt(
            attempted, didPresent: false, wasCancelled: false, current: attempted
        ))
    }

    func testShouldClearAfterPresentAttempt_presented_keepsState() {
        XCTAssertFalse(QuickLookPresentationPolicy.shouldClearAfterPresentAttempt(
            attempted, didPresent: true, wasCancelled: false, current: attempted
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
