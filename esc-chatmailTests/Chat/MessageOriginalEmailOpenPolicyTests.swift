import XCTest
@testable import esc_chatmail

final class MessageOriginalEmailOpenPolicyTests: XCTestCase {
    func testPlainTextBubbleBodyDoesNotOpenOriginalEmail() {
        XCTAssertFalse(
            MessageOriginalEmailOpenPolicy.bodyTapOpensOriginal(showHTMLPreview: false)
        )
    }

    func testRichPreviewCardBodyStillOpensOriginalEmail() {
        XCTAssertTrue(
            MessageOriginalEmailOpenPolicy.bodyTapOpensOriginal(showHTMLPreview: true)
        )
    }

    func testPlainTextWithOriginalContentShowsExplicitViewOriginalAffordance() {
        XCTAssertTrue(
            MessageOriginalEmailOpenPolicy.showsExplicitOriginalAffordance(
                hasOriginalEmailContent: true,
                hasVisibleText: true,
                showHTMLPreview: false
            )
        )
    }

    func testPlainTextWithoutOriginalContentDoesNotShowViewOriginalAffordance() {
        XCTAssertFalse(
            MessageOriginalEmailOpenPolicy.showsExplicitOriginalAffordance(
                hasOriginalEmailContent: false,
                hasVisibleText: true,
                showHTMLPreview: false
            )
        )
    }
}
