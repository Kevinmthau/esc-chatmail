import XCTest
@testable import esc_chatmail

final class MessageOriginalEmailOpenPolicyTests: XCTestCase {
    // Revert-check: MessageOriginalEmailOpenPolicy.textBubbleTapOpensOriginal —
    // reverting to the old rule (a text bubble never opened the original on
    // tap; a separate "View original" pill did) fails this test.
    //
    // HONEST SCOPE: this pins the decision only. That
    // MessageContentView.textBubble(text:) wraps the bubble in a Button when it
    // holds is view wiring; there is no UI test target to cover it.
    func testTextBubbleTapOpensOriginal_withOriginalContent_opensOriginal() {
        XCTAssertTrue(
            MessageOriginalEmailOpenPolicy.textBubbleTapOpensOriginal(hasOriginalEmailContent: true)
        )
    }

    func testTextBubbleTapOpensOriginal_withoutOriginalContent_doesNotOpen() {
        XCTAssertFalse(
            MessageOriginalEmailOpenPolicy.textBubbleTapOpensOriginal(hasOriginalEmailContent: false)
        )
    }

    /// An optimistic row always has original content (its typed `bodyText`), so a failed reply's
    /// tap used to open the reader on the user's own unsent text.
    ///
    /// Revert-check: dropping the `offersSendRecovery` branch in
    /// `MessageOriginalEmailOpenPolicy.textBubbleTap` (so original content wins) fails this test.
    ///
    /// HONEST SCOPE: pins the decision only. That `MessageBubble` passes `sendRecoveryPrompt`
    /// exactly when `FailedSendRecoveryPolicy.prompt` is non-nil, and that the tap presents the
    /// dialog, is view wiring with no UI test target.
    func testTextBubbleTap_failedSendWithOriginalContent_presentsSendRecovery() {
        XCTAssertEqual(
            MessageOriginalEmailOpenPolicy.textBubbleTap(
                hasOriginalEmailContent: true,
                offersSendRecovery: true
            ),
            .sendRecovery
        )
        XCTAssertEqual(
            MessageOriginalEmailOpenPolicy.textBubbleTap(
                hasOriginalEmailContent: false,
                offersSendRecovery: true
            ),
            .sendRecovery
        )
    }

    func testTextBubbleTap_withoutSendRecovery_keepsOriginalEmailRule() {
        XCTAssertEqual(
            MessageOriginalEmailOpenPolicy.textBubbleTap(
                hasOriginalEmailContent: true,
                offersSendRecovery: false
            ),
            .originalEmail
        )
        XCTAssertEqual(
            MessageOriginalEmailOpenPolicy.textBubbleTap(
                hasOriginalEmailContent: false,
                offersSendRecovery: false
            ),
            .none
        )
    }
}
