import XCTest
@testable import esc_chatmail

final class MessageOriginalEmailOpenPolicyTests: XCTestCase {
    // Revert-check: the `hasOriginalEmailContent` disjunct in
    // MessageOriginalEmailOpenPolicy.bodyTapOpensOriginal — reverting to the
    // preview-only rule (text bubbles did not open on tap; a separate
    // "View original" pill did) fails this test.
    //
    // HONEST SCOPE: this pins the decision only. That
    // MessageContentView.textBubble(text:) wraps the bubble in a Button when it
    // holds is view wiring; there is no UI test target to cover it.
    func testBodyTapOpensOriginal_textBubbleWithOriginalContent_opensOriginal() {
        XCTAssertTrue(
            MessageOriginalEmailOpenPolicy.bodyTapOpensOriginal(
                showHTMLPreview: false,
                hasOriginalEmailContent: true
            )
        )
    }

    func testBodyTapOpensOriginal_textBubbleWithoutOriginalContent_doesNotOpen() {
        XCTAssertFalse(
            MessageOriginalEmailOpenPolicy.bodyTapOpensOriginal(
                showHTMLPreview: false,
                hasOriginalEmailContent: false
            )
        )
    }

    func testBodyTapOpensOriginal_richPreviewCard_opensOriginal() {
        XCTAssertTrue(
            MessageOriginalEmailOpenPolicy.bodyTapOpensOriginal(
                showHTMLPreview: true,
                hasOriginalEmailContent: false
            )
        )
    }
}
