import XCTest
@testable import esc_chatmail

final class MessageDisplayPolicyTests: XCTestCase {
    func testShouldShowHTMLPreview_personalHTMLMessage_returnsFalse() {
        let shouldShow = MessageDisplayPolicy.shouldShowHTMLPreview(.init(
            hasHTMLSource: true,
            isForwardedEmail: false,
            isNewsletter: false,
            hasRichHTMLContent: false,
            isFromMe: false,
            isOneToOneConversation: true,
            subject: "Lunch?",
            senderEmail: nil
        ))

        XCTAssertFalse(shouldShow)
    }

    func testShouldShowHTMLPreview_forwardedMessageWithHTML_returnsTrue() {
        let shouldShow = MessageDisplayPolicy.shouldShowHTMLPreview(.init(
            hasHTMLSource: true,
            isForwardedEmail: true,
            isNewsletter: false,
            hasRichHTMLContent: false,
            isFromMe: false,
            isOneToOneConversation: true,
            subject: "Fwd: Details",
            senderEmail: nil
        ))

        XCTAssertTrue(shouldShow)
    }

    func testShouldShowHTMLPreview_forwardedMessageFromMe_returnsFalse() {
        let shouldShow = MessageDisplayPolicy.shouldShowHTMLPreview(.init(
            hasHTMLSource: true,
            isForwardedEmail: true,
            isNewsletter: false,
            hasRichHTMLContent: false,
            isFromMe: true,
            isOneToOneConversation: true,
            subject: "Fwd: Details",
            senderEmail: nil
        ))

        XCTAssertFalse(shouldShow)
    }

    func testShouldShowHTMLPreview_newsletterWithHTML_returnsTrue() {
        let shouldShow = MessageDisplayPolicy.shouldShowHTMLPreview(.init(
            hasHTMLSource: true,
            isForwardedEmail: false,
            isNewsletter: true,
            hasRichHTMLContent: false,
            isFromMe: false,
            isOneToOneConversation: false,
            subject: "Weekly update",
            senderEmail: nil
        ))

        XCTAssertTrue(shouldShow)
    }

    func testShouldShowHTMLPreview_newsletterWithoutHTMLMetadata_returnsTrue() {
        let shouldShow = MessageDisplayPolicy.shouldShowHTMLPreview(.init(
            hasHTMLSource: false,
            isForwardedEmail: false,
            isNewsletter: true,
            hasRichHTMLContent: false,
            isFromMe: false,
            isOneToOneConversation: true,
            subject: "Tickets Now On Sale for the Margaret Mead Film Festival",
            senderEmail: "publicprograms@email.amnh.org"
        ))

        XCTAssertTrue(shouldShow)
    }

    func testShouldShowHTMLPreview_richTransactionalHTML_oneToOne_returnsTrue() {
        let shouldShow = MessageDisplayPolicy.shouldShowHTMLPreview(.init(
            hasHTMLSource: true,
            isForwardedEmail: false,
            isNewsletter: false,
            hasRichHTMLContent: true,
            isFromMe: false,
            isOneToOneConversation: true,
            subject: "Thanks",
            senderEmail: nil
        ))

        XCTAssertTrue(shouldShow)
    }

    func testShouldShowHTMLPreview_calendarInviteWithoutRichHTML_returnsTrue() {
        let shouldShow = MessageDisplayPolicy.shouldShowHTMLPreview(.init(
            hasHTMLSource: true,
            isForwardedEmail: false,
            isNewsletter: false,
            hasRichHTMLContent: false,
            isFromMe: false,
            isOneToOneConversation: true,
            subject: "Invitation: Board sync @ Mon May 5, 2026 9:00am - 9:30am (EDT)",
            senderEmail: "calendar-notification@google.com",
            isLikelyCalendarInvite: true
        ))

        XCTAssertTrue(shouldShow)
    }

    func testShouldShowHTMLPreview_richTransactionalHTML_groupConversation_returnsTrue() {
        let shouldShow = MessageDisplayPolicy.shouldShowHTMLPreview(.init(
            hasHTMLSource: true,
            isForwardedEmail: false,
            isNewsletter: false,
            hasRichHTMLContent: true,
            isFromMe: false,
            isOneToOneConversation: false,
            subject: "Agenda",
            senderEmail: nil
        ))

        XCTAssertTrue(shouldShow)
    }

    func testShouldShowHTMLPreview_groupReplySubject_notNewsletter_returnsFalse() {
        let shouldShow = MessageDisplayPolicy.shouldShowHTMLPreview(.init(
            hasHTMLSource: true,
            isForwardedEmail: false,
            isNewsletter: false,
            hasRichHTMLContent: true,
            isFromMe: false,
            isOneToOneConversation: false,
            subject: "Re: Next steps",
            senderEmail: nil
        ))

        XCTAssertFalse(shouldShow)
    }

    func testShouldShowHTMLPreview_oneToOneReplySubject_overridesNewsletterFalsePositive() {
        let shouldShow = MessageDisplayPolicy.shouldShowHTMLPreview(.init(
            hasHTMLSource: true,
            isForwardedEmail: false,
            isNewsletter: true,
            hasRichHTMLContent: true,
            isFromMe: false,
            isOneToOneConversation: true,
            subject: "Re: Lending Follow up",
            senderEmail: "friend@example.com"
        ))

        XCTAssertFalse(shouldShow)
    }

    func testShouldShowHTMLPreview_oneToOneReplyFromTrustedTransactionalSender_returnsTrue() {
        let shouldShow = MessageDisplayPolicy.shouldShowHTMLPreview(.init(
            hasHTMLSource: true,
            isForwardedEmail: false,
            isNewsletter: false,
            hasRichHTMLContent: true,
            isFromMe: false,
            isOneToOneConversation: true,
            subject: "Re: ryfa-7369 sent a message about Item #1234",
            senderEmail: "ryfa73_izw3749pf@members.ebay.com"
        ))

        XCTAssertTrue(shouldShow)
    }

    func testShouldShowHTMLPreview_oneToOneReplyFromTrustedTransactionalSubdomain_returnsTrue() {
        let shouldShow = MessageDisplayPolicy.shouldShowHTMLPreview(.init(
            hasHTMLSource: true,
            isForwardedEmail: false,
            isNewsletter: false,
            hasRichHTMLContent: true,
            isFromMe: false,
            isOneToOneConversation: true,
            subject: "Re: New message about your listing",
            senderEmail: "xyz123@marketplace.amazon.com"
        ))

        XCTAssertTrue(shouldShow)
    }

    func testShouldShowHTMLPreview_oneToOneReplyFromBillSender_returnsTrue() {
        let shouldShow = MessageDisplayPolicy.shouldShowHTMLPreview(.init(
            hasHTMLSource: true,
            isForwardedEmail: false,
            isNewsletter: false,
            hasRichHTMLContent: true,
            isFromMe: false,
            isOneToOneConversation: true,
            subject: "Re: Bill approval required",
            senderEmail: "account-services@inform.bill.com"
        ))

        XCTAssertTrue(shouldShow)
    }

    func testShouldShowHTMLPreview_oneToOneReplyFromBillSender_withoutHTMLMetadata_returnsTrue() {
        let shouldShow = MessageDisplayPolicy.shouldShowHTMLPreview(.init(
            hasHTMLSource: false,
            isForwardedEmail: false,
            isNewsletter: false,
            hasRichHTMLContent: false,
            isFromMe: false,
            isOneToOneConversation: true,
            subject: "Re: Bill approval required",
            senderEmail: "account-services@inform.bill.com"
        ))

        XCTAssertTrue(shouldShow)
    }

    func testShouldShowHTMLPreview_formattedFromHeaderForBillSender_returnsTrue() {
        let shouldShow = MessageDisplayPolicy.shouldShowHTMLPreview(.init(
            hasHTMLSource: false,
            isForwardedEmail: false,
            isNewsletter: false,
            hasRichHTMLContent: false,
            isFromMe: false,
            isOneToOneConversation: true,
            subject: "Your approval is needed",
            senderEmail: "BILL <account-services@inform.bill.com>"
        ))

        XCTAssertTrue(shouldShow)
    }

    func testShouldShowHTMLPreview_fromMeInOneToOne_returnsFalse() {
        let shouldShow = MessageDisplayPolicy.shouldShowHTMLPreview(.init(
            hasHTMLSource: true,
            isForwardedEmail: false,
            isNewsletter: true,
            hasRichHTMLContent: true,
            isFromMe: true,
            isOneToOneConversation: true,
            subject: "Status",
            senderEmail: nil
        ))

        XCTAssertFalse(shouldShow)
    }

    func testShouldShowHTMLPreview_noHTMLSource_andNotRich_returnsFalse() {
        let shouldShow = MessageDisplayPolicy.shouldShowHTMLPreview(.init(
            hasHTMLSource: false,
            isForwardedEmail: true,
            isNewsletter: true,
            hasRichHTMLContent: false,
            isFromMe: false,
            isOneToOneConversation: false,
            subject: "Anything",
            senderEmail: nil
        ))

        XCTAssertFalse(shouldShow)
    }

    func testShouldShowHTMLPreview_noHTMLSource_butRichContent_returnsTrue() {
        let shouldShow = MessageDisplayPolicy.shouldShowHTMLPreview(.init(
            hasHTMLSource: false,
            isForwardedEmail: false,
            isNewsletter: false,
            hasRichHTMLContent: true,
            isFromMe: false,
            isOneToOneConversation: true,
            subject: "Your approval is needed",
            senderEmail: nil
        ))

        XCTAssertTrue(shouldShow)
    }

    // MARK: - Text loading placeholder

    private func showsTextLoadingPlaceholder(
        hasLoadedContent: Bool = false,
        hasHTMLSource: Bool = true,
        isForwardedEmail: Bool = false,
        isFromMe: Bool = true,
        isNewsletter: Bool = false,
        isLikelyCalendarInvite: Bool = false,
        senderEmail: String? = nil,
        chatPreviewText: String? = "On my way, see you at 6",
        hasDisplayableAttachments: Bool = false
    ) -> Bool {
        MessageDisplayPolicy.showsTextLoadingPlaceholder(
            hasLoadedContent: hasLoadedContent,
            hasHTMLSource: hasHTMLSource,
            isForwardedEmail: isForwardedEmail,
            isFromMe: isFromMe,
            isNewsletter: isNewsletter,
            isLikelyCalendarInvite: isLikelyCalendarInvite,
            senderEmail: senderEmail,
            chatPreviewText: chatPreviewText,
            hasDisplayableAttachments: hasDisplayableAttachments
        )
    }

    /// Sync replaces an optimistic reply with Gmail's echo, a new object ID, so the bubble
    /// remounts with a fresh view model whose content has not loaded, and the echo always has an
    /// HTML source. Its stored preview is the text the load will publish, so it renders now.
    ///
    /// Revert-check: deleting the `rendersStoredOwnPreview` exemption in
    /// `MessageDisplayPolicy.showsTextLoadingPlaceholder` (back to "HTML source and not loaded →
    /// pill") fails this test.
    ///
    /// HONEST SCOPE: this pins the decision. That `MessageContentView.textContent` renders the
    /// stored text when it holds is view wiring; there is no UI test target to cover it.
    func testShowsTextLoadingPlaceholder_ownHTMLEchoWithStoredPreviewBeforeLoad_rendersText() {
        XCTAssertFalse(showsTextLoadingPlaceholder())
    }

    /// The comment in `MessageContentView.textContent` still holds for incoming mail with no
    /// stored preview: until content detection finishes, its only text is raw/partial
    /// HTML-derived text.
    func testShowsTextLoadingPlaceholder_incomingHTMLBeforeLoad_showsPlaceholder() {
        XCTAssertTrue(showsTextLoadingPlaceholder(isFromMe: false, chatPreviewText: nil))
    }

    /// An incoming row's stored preview is the text the load will publish verbatim, and the
    /// loader's only other output for it is the rich-content verdict. Each pill → bubble swap
    /// reset the hidden initial-anchor pass, so every chat of incoming HTML bubbles opened late.
    /// Displayed attachments and a non-transactional sender change nothing.
    ///
    /// Revert-check: deleting the `rendersStoredIncomingPreview` branch in
    /// `MessageDisplayPolicy.showsTextLoadingPlaceholder` (back to "incoming HTML source and not
    /// loaded → pill") fails this test.
    ///
    /// HONEST SCOPE: this pins the decision. That `MessageContentView.textContent` renders the
    /// stored text when it holds, and passes `effectiveSenderEmail`, is view wiring; there is no
    /// UI test target to cover it.
    func testShowsTextLoadingPlaceholder_incomingHTMLWithStoredPreviewBeforeLoad_rendersText() {
        XCTAssertFalse(showsTextLoadingPlaceholder(isFromMe: false))
        XCTAssertFalse(showsTextLoadingPlaceholder(isFromMe: false, senderEmail: "alice@example.com"))
        XCTAssertFalse(showsTextLoadingPlaceholder(isFromMe: false, hasDisplayableAttachments: true))
    }

    /// Newsletter and calendar-invite rows can route to a preview card on stored inputs alone, so
    /// their stored preview is not their final rendering: the card would replace it.
    ///
    /// Revert-check: dropping `!isNewsletter` or `!isLikelyCalendarInvite` from
    /// `rendersStoredIncomingPreview` in `MessageDisplayPolicy.showsTextLoadingPlaceholder` fails
    /// the matching assertion.
    func testShowsTextLoadingPlaceholder_incomingNewsletterOrInviteWithStoredPreview_showsPlaceholder() {
        XCTAssertTrue(showsTextLoadingPlaceholder(isFromMe: false, isNewsletter: true))
        XCTAssertTrue(showsTextLoadingPlaceholder(isFromMe: false, isLikelyCalendarInvite: true))
    }

    /// `shouldShowHTMLPreview` routes a trusted transactional sender to a preview card without
    /// waiting for rich-content classification, so its stored preview is not its final rendering
    /// either. The sender is matched on its parsed domain, as the preview routing does.
    ///
    /// Revert-check: dropping `!isTrustedTransactionalSender(senderEmail)` from
    /// `rendersStoredIncomingPreview` in `MessageDisplayPolicy.showsTextLoadingPlaceholder` fails
    /// this test.
    func testShowsTextLoadingPlaceholder_incomingTrustedTransactionalSenderWithStoredPreview_showsPlaceholder() {
        XCTAssertTrue(showsTextLoadingPlaceholder(isFromMe: false, senderEmail: "noreply@members.ebay.com"))
        XCTAssertTrue(showsTextLoadingPlaceholder(isFromMe: false, senderEmail: "ship-confirm@amazon.com"))
        XCTAssertFalse(showsTextLoadingPlaceholder(isFromMe: false, senderEmail: "x@members.ebay.com.evil.example"))
    }

    /// Forwarded rows wait for the structured forward summary whatever text they store.
    ///
    /// Revert-check: moving the `if isForwardedEmail { return true }` early return in
    /// `MessageDisplayPolicy.showsTextLoadingPlaceholder` below the incoming-row branch, or
    /// deleting it, fails this test.
    func testShowsTextLoadingPlaceholder_incomingForwardedWithStoredPreview_showsPlaceholder() {
        XCTAssertTrue(showsTextLoadingPlaceholder(isForwardedEmail: true, isFromMe: false))
        XCTAssertTrue(showsTextLoadingPlaceholder(hasHTMLSource: false, isForwardedEmail: true, isFromMe: false))
    }

    /// A blank stored preview is no stored preview: the row has no final text to show yet.
    ///
    /// Revert-check: testing `chatPreviewText != nil` instead of
    /// `MessagePreviewText.nonEmpty(chatPreviewText) != nil` in the incoming-row branch of
    /// `MessageDisplayPolicy.showsTextLoadingPlaceholder` fails this test.
    func testShowsTextLoadingPlaceholder_incomingWithBlankStoredPreview_showsPlaceholder() {
        XCTAssertTrue(showsTextLoadingPlaceholder(isFromMe: false, chatPreviewText: ""))
        XCTAssertTrue(showsTextLoadingPlaceholder(isFromMe: false, chatPreviewText: " \n\t "))
    }

    func testShowsTextLoadingPlaceholder_ownHTMLWithoutStoredPreview_showsPlaceholder() {
        XCTAssertTrue(showsTextLoadingPlaceholder(chatPreviewText: nil))
        XCTAssertTrue(showsTextLoadingPlaceholder(chatPreviewText: " \n\t "))
    }

    /// An attachments-only reply has no stored preview (no text of its own) and an HTML source,
    /// and its load finds no text either: the attachments are the whole bubble. The pill showed
    /// "Loading..." under them and then vanished, on every fresh mount of the row (reopening the
    /// chat, the row re-entering the window, an echo that landed while the chat was closed).
    ///
    /// Revert-check: dropping `&& !hasDisplayableAttachments` from
    /// `MessageDisplayPolicy.showsTextLoadingPlaceholder` fails this test.
    ///
    /// HONEST SCOPE: this pins the decision. That `MessageContentView.textContent` passes the
    /// bubble's displayed (filtered) attachments is view wiring with no UI test target.
    func testShowsTextLoadingPlaceholder_ownAttachmentsOnlyRowWithoutStoredPreview_skipsPlaceholder() {
        XCTAssertFalse(showsTextLoadingPlaceholder(chatPreviewText: nil, hasDisplayableAttachments: true))
        XCTAssertFalse(showsTextLoadingPlaceholder(chatPreviewText: " \n\t ", hasDisplayableAttachments: true))
    }

    /// Only the user's own text-routed rows get the attachments exemption. Incoming mail without a
    /// stored preview still waits for content detection, and forwarded, newsletter and invite rows
    /// can still route elsewhere, whatever attachments they carry.
    func testShowsTextLoadingPlaceholder_attachmentsOnIncomingForwardedNewsletterOrInvite_showsPlaceholder() {
        XCTAssertTrue(showsTextLoadingPlaceholder(isFromMe: false, chatPreviewText: nil, hasDisplayableAttachments: true))
        XCTAssertTrue(showsTextLoadingPlaceholder(isFromMe: false, isNewsletter: true, hasDisplayableAttachments: true))
        XCTAssertTrue(
            showsTextLoadingPlaceholder(isFromMe: false, isLikelyCalendarInvite: true, hasDisplayableAttachments: true)
        )
        XCTAssertTrue(
            showsTextLoadingPlaceholder(isForwardedEmail: true, chatPreviewText: nil, hasDisplayableAttachments: true)
        )
        XCTAssertTrue(showsTextLoadingPlaceholder(isNewsletter: true, chatPreviewText: nil, hasDisplayableAttachments: true))
        XCTAssertTrue(
            showsTextLoadingPlaceholder(isLikelyCalendarInvite: true, chatPreviewText: nil, hasDisplayableAttachments: true)
        )
    }

    /// Forwarded rows wait for the structured forward summary, and newsletter/invite rows can
    /// route to a preview card, so the stored preview is not their final text.
    func testShowsTextLoadingPlaceholder_ownForwardedNewsletterOrInviteBeforeLoad_showsPlaceholder() {
        XCTAssertTrue(showsTextLoadingPlaceholder(isForwardedEmail: true))
        XCTAssertTrue(showsTextLoadingPlaceholder(hasHTMLSource: false, isForwardedEmail: true))
        XCTAssertTrue(showsTextLoadingPlaceholder(isNewsletter: true))
        XCTAssertTrue(showsTextLoadingPlaceholder(isLikelyCalendarInvite: true))
    }

    func testShowsTextLoadingPlaceholder_withoutHTMLSourceOrOnceLoaded_rendersText() {
        XCTAssertFalse(showsTextLoadingPlaceholder(hasHTMLSource: false, isFromMe: false, chatPreviewText: nil))
        XCTAssertFalse(showsTextLoadingPlaceholder(hasLoadedContent: true, isFromMe: false, chatPreviewText: nil))
        XCTAssertFalse(showsTextLoadingPlaceholder(hasLoadedContent: true, isForwardedEmail: true))
    }

    func testIsTrustedTransactionalSender_rejectsSpoofedDomains() {
        XCTAssertFalse(MessageDisplayPolicy.isTrustedTransactionalSender("x@members.ebay.com.evil.example"))
        XCTAssertFalse(MessageDisplayPolicy.isTrustedTransactionalSender("\"ship-confirm@amazon.com\" <attacker@evil.example>"))
        XCTAssertFalse(MessageDisplayPolicy.isTrustedTransactionalSender("x@notamazon.com"))
    }

    func testIsTrustedTransactionalSender_acceptsTrustedDomainsAndSubdomains() {
        XCTAssertTrue(MessageDisplayPolicy.isTrustedTransactionalSender("ryfa73_izw3749pf@members.ebay.com"))
        XCTAssertTrue(MessageDisplayPolicy.isTrustedTransactionalSender("xyz123@marketplace.amazon.com"))
        XCTAssertTrue(MessageDisplayPolicy.isTrustedTransactionalSender("BILL <approvals@hq.bill.com>"))
    }
}
