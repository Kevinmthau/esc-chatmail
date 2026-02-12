import XCTest
@testable import esc_chatmail

final class MessageDisplayPolicyTests: XCTestCase {
    func testShouldShowHTMLPreview_personalHTMLMessage_returnsFalse() {
        let shouldShow = MessageDisplayPolicy.shouldShowHTMLPreview(
            hasHTMLSource: true,
            isForwardedEmail: false,
            isNewsletter: false
        )

        XCTAssertFalse(shouldShow)
    }

    func testShouldShowHTMLPreview_forwardedMessageWithHTML_returnsTrue() {
        let shouldShow = MessageDisplayPolicy.shouldShowHTMLPreview(
            hasHTMLSource: true,
            isForwardedEmail: true,
            isNewsletter: false
        )

        XCTAssertTrue(shouldShow)
    }

    func testShouldShowHTMLPreview_newsletterWithHTML_returnsTrue() {
        let shouldShow = MessageDisplayPolicy.shouldShowHTMLPreview(
            hasHTMLSource: true,
            isForwardedEmail: false,
            isNewsletter: true
        )

        XCTAssertTrue(shouldShow)
    }

    func testShouldShowHTMLPreview_noHTMLSource_returnsFalse() {
        let shouldShow = MessageDisplayPolicy.shouldShowHTMLPreview(
            hasHTMLSource: false,
            isForwardedEmail: true,
            isNewsletter: true
        )

        XCTAssertFalse(shouldShow)
    }
}
