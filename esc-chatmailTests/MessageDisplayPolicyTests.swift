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
            subject: "Lunch?",
            senderEmail: nil
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
            subject: "Fwd: Details",
            senderEmail: nil
        )

        XCTAssertTrue(shouldShow)
    }

    func testShouldShowHTMLPreview_forwardedMessageFromMe_returnsFalse() {
        let shouldShow = MessageDisplayPolicy.shouldShowHTMLPreview(
            hasHTMLSource: true,
            isForwardedEmail: true,
            isNewsletter: false,
            hasRichHTMLContent: false,
            isFromMe: true,
            isOneToOneConversation: true,
            subject: "Fwd: Details",
            senderEmail: nil
        )

        XCTAssertFalse(shouldShow)
    }

    func testShouldShowHTMLPreview_newsletterWithHTML_returnsTrue() {
        let shouldShow = MessageDisplayPolicy.shouldShowHTMLPreview(
            hasHTMLSource: true,
            isForwardedEmail: false,
            isNewsletter: true,
            hasRichHTMLContent: false,
            isFromMe: false,
            isOneToOneConversation: false,
            subject: "Weekly update",
            senderEmail: nil
        )

        XCTAssertTrue(shouldShow)
    }

    func testShouldShowHTMLPreview_newsletterWithoutHTMLMetadata_returnsTrue() {
        let shouldShow = MessageDisplayPolicy.shouldShowHTMLPreview(
            hasHTMLSource: false,
            isForwardedEmail: false,
            isNewsletter: true,
            hasRichHTMLContent: false,
            isFromMe: false,
            isOneToOneConversation: true,
            subject: "Tickets Now On Sale for the Margaret Mead Film Festival",
            senderEmail: "publicprograms@email.amnh.org"
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
            subject: "Thanks",
            senderEmail: nil
        )

        XCTAssertTrue(shouldShow)
    }

    func testShouldShowHTMLPreview_calendarInviteWithoutRichHTML_returnsTrue() {
        let shouldShow = MessageDisplayPolicy.shouldShowHTMLPreview(
            hasHTMLSource: true,
            isForwardedEmail: false,
            isNewsletter: false,
            hasRichHTMLContent: false,
            isFromMe: false,
            isOneToOneConversation: true,
            subject: "Invitation: Board sync @ Mon May 5, 2026 9:00am - 9:30am (EDT)",
            senderEmail: "calendar-notification@google.com",
            isLikelyCalendarInvite: true
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
            subject: "Agenda",
            senderEmail: nil
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
            subject: "Re: Next steps",
            senderEmail: nil
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
            subject: "Re: Lending Follow up",
            senderEmail: "friend@example.com"
        )

        XCTAssertFalse(shouldShow)
    }

    func testShouldShowHTMLPreview_oneToOneReplyFromTrustedTransactionalSender_returnsTrue() {
        let shouldShow = MessageDisplayPolicy.shouldShowHTMLPreview(
            hasHTMLSource: true,
            isForwardedEmail: false,
            isNewsletter: false,
            hasRichHTMLContent: true,
            isFromMe: false,
            isOneToOneConversation: true,
            subject: "Re: ryfa-7369 sent a message about Item #1234",
            senderEmail: "ryfa73_izw3749pf@members.ebay.com"
        )

        XCTAssertTrue(shouldShow)
    }

    func testShouldShowHTMLPreview_oneToOneReplyFromTrustedTransactionalSubdomain_returnsTrue() {
        let shouldShow = MessageDisplayPolicy.shouldShowHTMLPreview(
            hasHTMLSource: true,
            isForwardedEmail: false,
            isNewsletter: false,
            hasRichHTMLContent: true,
            isFromMe: false,
            isOneToOneConversation: true,
            subject: "Re: New message about your listing",
            senderEmail: "xyz123@marketplace.amazon.com"
        )

        XCTAssertTrue(shouldShow)
    }

    func testShouldShowHTMLPreview_oneToOneReplyFromBillSender_returnsTrue() {
        let shouldShow = MessageDisplayPolicy.shouldShowHTMLPreview(
            hasHTMLSource: true,
            isForwardedEmail: false,
            isNewsletter: false,
            hasRichHTMLContent: true,
            isFromMe: false,
            isOneToOneConversation: true,
            subject: "Re: Bill approval required",
            senderEmail: "account-services@inform.bill.com"
        )

        XCTAssertTrue(shouldShow)
    }

    func testShouldShowHTMLPreview_oneToOneReplyFromBillSender_withoutHTMLMetadata_returnsTrue() {
        let shouldShow = MessageDisplayPolicy.shouldShowHTMLPreview(
            hasHTMLSource: false,
            isForwardedEmail: false,
            isNewsletter: false,
            hasRichHTMLContent: false,
            isFromMe: false,
            isOneToOneConversation: true,
            subject: "Re: Bill approval required",
            senderEmail: "account-services@inform.bill.com"
        )

        XCTAssertTrue(shouldShow)
    }

    func testShouldShowHTMLPreview_formattedFromHeaderForBillSender_returnsTrue() {
        let shouldShow = MessageDisplayPolicy.shouldShowHTMLPreview(
            hasHTMLSource: false,
            isForwardedEmail: false,
            isNewsletter: false,
            hasRichHTMLContent: false,
            isFromMe: false,
            isOneToOneConversation: true,
            subject: "Your approval is needed",
            senderEmail: "BILL <account-services@inform.bill.com>"
        )

        XCTAssertTrue(shouldShow)
    }

    func testShouldShowHTMLPreview_fromMeInOneToOne_returnsFalse() {
        let shouldShow = MessageDisplayPolicy.shouldShowHTMLPreview(
            hasHTMLSource: true,
            isForwardedEmail: false,
            isNewsletter: true,
            hasRichHTMLContent: true,
            isFromMe: true,
            isOneToOneConversation: true,
            subject: "Status",
            senderEmail: nil
        )

        XCTAssertFalse(shouldShow)
    }

    func testShouldShowHTMLPreview_noHTMLSource_andNotRich_returnsFalse() {
        let shouldShow = MessageDisplayPolicy.shouldShowHTMLPreview(
            hasHTMLSource: false,
            isForwardedEmail: true,
            isNewsletter: true,
            hasRichHTMLContent: false,
            isFromMe: false,
            isOneToOneConversation: false,
            subject: "Anything",
            senderEmail: nil
        )

        XCTAssertFalse(shouldShow)
    }

    func testShouldShowHTMLPreview_noHTMLSource_butRichContent_returnsTrue() {
        let shouldShow = MessageDisplayPolicy.shouldShowHTMLPreview(
            hasHTMLSource: false,
            isForwardedEmail: false,
            isNewsletter: false,
            hasRichHTMLContent: true,
            isFromMe: false,
            isOneToOneConversation: true,
            subject: "Your approval is needed",
            senderEmail: nil
        )

        XCTAssertTrue(shouldShow)
    }
}
