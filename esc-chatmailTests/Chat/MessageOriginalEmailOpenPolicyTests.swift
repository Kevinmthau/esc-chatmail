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
}
