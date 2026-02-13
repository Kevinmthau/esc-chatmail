import XCTest
@testable import esc_chatmail

final class MessageDisplayPolicyTests: XCTestCase {
    func testShouldShowHTMLPreview_personalHTMLMessage_returnsFalse() {
        let shouldShow = MessageDisplayPolicy.shouldShowHTMLPreview(
            hasHTMLSource: true,
            isForwardedEmail: false,
            isNewsletter: false,
            hasRichHTMLContent: false
        )

        XCTAssertFalse(shouldShow)
    }

    func testShouldShowHTMLPreview_forwardedMessageWithHTML_returnsTrue() {
        let shouldShow = MessageDisplayPolicy.shouldShowHTMLPreview(
            hasHTMLSource: true,
            isForwardedEmail: true,
            isNewsletter: false,
            hasRichHTMLContent: false
        )

        XCTAssertTrue(shouldShow)
    }

    func testShouldShowHTMLPreview_newsletterWithHTML_returnsTrue() {
        let shouldShow = MessageDisplayPolicy.shouldShowHTMLPreview(
            hasHTMLSource: true,
            isForwardedEmail: false,
            isNewsletter: true,
            hasRichHTMLContent: false
        )

        XCTAssertTrue(shouldShow)
    }

    func testShouldShowHTMLPreview_richTransactionalHTML_returnsTrue() {
        let shouldShow = MessageDisplayPolicy.shouldShowHTMLPreview(
            hasHTMLSource: true,
            isForwardedEmail: false,
            isNewsletter: false,
            hasRichHTMLContent: true
        )

        XCTAssertTrue(shouldShow)
    }

    func testShouldShowHTMLPreview_noHTMLSource_returnsFalse() {
        let shouldShow = MessageDisplayPolicy.shouldShowHTMLPreview(
            hasHTMLSource: false,
            isForwardedEmail: true,
            isNewsletter: true,
            hasRichHTMLContent: true
        )

        XCTAssertFalse(shouldShow)
    }
}
