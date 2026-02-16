import XCTest
@testable import esc_chatmail

final class MessageDisplayPolicyTests: XCTestCase {
    func testShouldShowHTMLPreview_personalHTMLMessage_returnsFalse() {
        let shouldShow = MessageDisplayPolicy.shouldShowHTMLPreview(
            hasHTMLSource: true,
            isForwardedEmail: false,
            isNewsletter: false,
            hasRichHTMLContent: false,
            isFromMe: false,
            isOneToOneConversation: true,
            subject: "Lunch?"
        )

        XCTAssertFalse(shouldShow)
    }

    func testShouldShowHTMLPreview_forwardedMessageWithHTML_returnsTrue() {
        let shouldShow = MessageDisplayPolicy.shouldShowHTMLPreview(
            hasHTMLSource: true,
            isForwardedEmail: true,
            isNewsletter: false,
            hasRichHTMLContent: false,
            isFromMe: false,
            isOneToOneConversation: true,
            subject: "Fwd: Details"
        )

        XCTAssertTrue(shouldShow)
    }

    func testShouldShowHTMLPreview_newsletterWithHTML_returnsTrue() {
        let shouldShow = MessageDisplayPolicy.shouldShowHTMLPreview(
            hasHTMLSource: true,
            isForwardedEmail: false,
            isNewsletter: true,
            hasRichHTMLContent: false,
            isFromMe: false,
            isOneToOneConversation: false,
            subject: "Weekly update"
        )

        XCTAssertTrue(shouldShow)
    }

    func testShouldShowHTMLPreview_richTransactionalHTML_oneToOne_returnsTrue() {
        let shouldShow = MessageDisplayPolicy.shouldShowHTMLPreview(
            hasHTMLSource: true,
            isForwardedEmail: false,
            isNewsletter: false,
            hasRichHTMLContent: true,
            isFromMe: false,
            isOneToOneConversation: true,
            subject: "Thanks"
        )

        XCTAssertTrue(shouldShow)
    }

    func testShouldShowHTMLPreview_richTransactionalHTML_groupConversation_returnsTrue() {
        let shouldShow = MessageDisplayPolicy.shouldShowHTMLPreview(
            hasHTMLSource: true,
            isForwardedEmail: false,
            isNewsletter: false,
            hasRichHTMLContent: true,
            isFromMe: false,
            isOneToOneConversation: false,
            subject: "Agenda"
        )

        XCTAssertTrue(shouldShow)
    }

    func testShouldShowHTMLPreview_groupReplySubject_notNewsletter_returnsFalse() {
        let shouldShow = MessageDisplayPolicy.shouldShowHTMLPreview(
            hasHTMLSource: true,
            isForwardedEmail: false,
            isNewsletter: false,
            hasRichHTMLContent: true,
            isFromMe: false,
            isOneToOneConversation: false,
            subject: "Re: Next steps"
        )

        XCTAssertFalse(shouldShow)
    }

    func testShouldShowHTMLPreview_oneToOneReplySubject_overridesNewsletterFalsePositive() {
        let shouldShow = MessageDisplayPolicy.shouldShowHTMLPreview(
            hasHTMLSource: true,
            isForwardedEmail: false,
            isNewsletter: true,
            hasRichHTMLContent: true,
            isFromMe: false,
            isOneToOneConversation: true,
            subject: "Re: Lending Follow up"
        )

        XCTAssertFalse(shouldShow)
    }

    func testShouldShowHTMLPreview_fromMeInOneToOne_returnsFalse() {
        let shouldShow = MessageDisplayPolicy.shouldShowHTMLPreview(
            hasHTMLSource: true,
            isForwardedEmail: false,
            isNewsletter: true,
            hasRichHTMLContent: true,
            isFromMe: true,
            isOneToOneConversation: true,
            subject: "Status"
        )

        XCTAssertFalse(shouldShow)
    }

    func testShouldShowHTMLPreview_noHTMLSource_returnsFalse() {
        let shouldShow = MessageDisplayPolicy.shouldShowHTMLPreview(
            hasHTMLSource: false,
            isForwardedEmail: true,
            isNewsletter: true,
            hasRichHTMLContent: true,
            isFromMe: false,
            isOneToOneConversation: false,
            subject: "Anything"
        )

        XCTAssertFalse(shouldShow)
    }
}
