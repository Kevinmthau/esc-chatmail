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

    /// The defaults describe the user's own reply echo before its load. `subject` defaults to nil,
    /// which is not a reply subject, so every incoming test states the subject its outcome
    /// depends on.
    private func showsTextLoadingPlaceholder(
        hasLoadedContent: Bool = false,
        hasHTMLSource: Bool = true,
        isForwardedEmail: Bool = false,
        isFromMe: Bool = true,
        isNewsletter: Bool = false,
        isLikelyCalendarInvite: Bool = false,
        isOneToOneConversation: Bool = true,
        subject: String? = nil,
        senderEmail: String? = nil,
        chatPreviewText: String? = "On my way, see you at 6",
        hasDisplayableAttachments: Bool = false
    ) -> Bool {
        MessageDisplayPolicy.showsTextLoadingPlaceholder(
            hasLoadedContent: hasLoadedContent,
            routing: MessageDisplayInput(
                hasHTMLSource: hasHTMLSource,
                isForwardedEmail: isForwardedEmail,
                isNewsletter: isNewsletter,
                hasRichHTMLContent: false,
                isFromMe: isFromMe,
                isOneToOneConversation: isOneToOneConversation,
                subject: subject,
                senderEmail: senderEmail,
                isLikelyCalendarInvite: isLikelyCalendarInvite
            ),
            chatPreviewText: chatPreviewText,
            hasDisplayableAttachments: hasDisplayableAttachments
        )
    }

    private static let placeholderSubjects: [String?] = [nil, "", "Lunch?", "Re: Lunch?", "  RE: lunch"]
    private static let placeholderSenders: [String?] = [nil, "alice@example.com", "noreply@members.ebay.com"]

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
    /// HTML-derived text. That is so even for a reply, which no load outcome routes to a card.
    func testShowsTextLoadingPlaceholder_incomingHTMLBeforeLoad_showsPlaceholder() {
        XCTAssertTrue(showsTextLoadingPlaceholder(isFromMe: false, chatPreviewText: nil))
        XCTAssertTrue(showsTextLoadingPlaceholder(isFromMe: false, subject: "Re: Dinner", chatPreviewText: nil))
    }

    /// A reply from an ordinary sender stays a text bubble whatever the load's rich-content
    /// verdict, so its stored preview is the text the load will publish verbatim and it renders
    /// now. Conversation kind, sender and displayed attachments change nothing.
    ///
    /// Revert-check: deleting the `rendersStoredIncomingPreview` branch in
    /// `MessageDisplayPolicy.showsTextLoadingPlaceholder` (back to "incoming HTML source and not
    /// loaded → pill") fails this test.
    ///
    /// HONEST SCOPE: this pins the decision. That `MessageBubble` hands `MessageContentView` the
    /// `MessageDisplayInput` it routed on, and that `textContent` renders the stored text when
    /// the decision holds, is view wiring; there is no UI test target to cover it.
    func testShowsTextLoadingPlaceholder_incomingReplyWithStoredPreviewBeforeLoad_rendersText() {
        XCTAssertFalse(showsTextLoadingPlaceholder(isFromMe: false, subject: "Re: Dinner"))
        XCTAssertFalse(
            showsTextLoadingPlaceholder(isFromMe: false, isOneToOneConversation: false, subject: "Re: Dinner")
        )
        XCTAssertFalse(showsTextLoadingPlaceholder(isFromMe: false, subject: "  RE: dinner"))
        XCTAssertFalse(
            showsTextLoadingPlaceholder(isFromMe: false, subject: "Re: Dinner", senderEmail: "alice@example.com")
        )
        XCTAssertFalse(
            showsTextLoadingPlaceholder(isFromMe: false, subject: "Re: Dinner", hasDisplayableAttachments: true)
        )
    }

    /// A row whose subject is not a reply routes to the preview card when the load's verdict is
    /// "rich" (a receipt, a notification), so its stored preview is not yet known to be its final
    /// rendering. Rendering it showed the stored text and then swapped it for the card.
    ///
    /// Revert-check: replacing `!loadCanRouteToHTMLPreview(routing)` in
    /// `rendersStoredIncomingPreview` with the flag list it superseded
    /// (`!routing.isNewsletter && !routing.isLikelyCalendarInvite &&
    /// !isTrustedTransactionalSender(routing.senderEmail)`), or dropping the term, fails this test.
    func testShowsTextLoadingPlaceholder_incomingStoredPreviewTheLoadCanRouteToCard_showsPlaceholder() {
        for subject in [nil, "", "Your receipt"] as [String?] {
            for isOneToOneConversation in [true, false] {
                XCTAssertTrue(
                    showsTextLoadingPlaceholder(
                        isFromMe: false,
                        isOneToOneConversation: isOneToOneConversation,
                        subject: subject
                    ),
                    "subject=\(subject ?? "nil") oneToOne=\(isOneToOneConversation)"
                )
                XCTAssertTrue(
                    MessageDisplayPolicy.shouldShowHTMLPreview(.init(
                        hasHTMLSource: true,
                        isForwardedEmail: false,
                        isNewsletter: false,
                        hasRichHTMLContent: true,
                        isFromMe: false,
                        isOneToOneConversation: isOneToOneConversation,
                        subject: subject,
                        senderEmail: nil
                    )),
                    "the rich outcome routes this row to a card"
                )
            }
        }
        XCTAssertTrue(
            showsTextLoadingPlaceholder(isFromMe: false, subject: "Your receipt", hasDisplayableAttachments: true)
        )
    }

    /// A newsletter or calendar-invite flag does not by itself make a card: for a sender that is
    /// not a trusted transactional one, the routing keeps every reply in a one-to-one
    /// conversation, and every reply not flagged as a newsletter in a group one, as a text bubble
    /// for either verdict. Those are the only flagged rows the content view asks about (the
    /// routing cards the rest, and every incoming trusted sender, before the load), and their
    /// stored preview is their final text.
    ///
    /// Revert-check: adding `!routing.isNewsletter` or `!routing.isLikelyCalendarInvite` back to
    /// `rendersStoredIncomingPreview` in `MessageDisplayPolicy.showsTextLoadingPlaceholder` fails
    /// the matching assertions.
    func testShowsTextLoadingPlaceholder_incomingNewsletterOrInviteReplyThatStaysText_rendersText() {
        XCTAssertFalse(showsTextLoadingPlaceholder(isFromMe: false, isNewsletter: true, subject: "Re: Dinner"))
        XCTAssertFalse(
            showsTextLoadingPlaceholder(isFromMe: false, isLikelyCalendarInvite: true, subject: "Re: Dinner")
        )
        XCTAssertFalse(
            showsTextLoadingPlaceholder(
                isFromMe: false,
                isLikelyCalendarInvite: true,
                isOneToOneConversation: false,
                subject: "Re: Dinner"
            )
        )
        XCTAssertFalse(
            showsTextLoadingPlaceholder(
                isFromMe: false,
                isNewsletter: true,
                isLikelyCalendarInvite: true,
                subject: "Re: Dinner"
            )
        )
    }

    /// The whole rule for an incoming HTML row with a stored preview, both directions at once:
    /// the pill shows exactly when the routing sends the row to a card for some rich-content
    /// verdict. The oracle builds each outcome with the full initializer, so it does not share
    /// `MessageDisplayInput.withRichHTMLContent` with the code under test. Trusted senders are
    /// included although the content view never asks about them (the routing cards them before
    /// the load): a direct call must still never answer "text" for one.
    ///
    /// Revert-check: the superseded flag list in `rendersStoredIncomingPreview` fails in both
    /// directions (text for a new-subject row the rich outcome cards; the pill for a one-to-one
    /// newsletter or invite reply no outcome cards). Narrowing
    /// `MessageDisplayPolicy.loadCanRouteToHTMLPreview` to `shouldShowHTMLPreview(input)` fails
    /// the first direction.
    ///
    /// HONEST SCOPE: the oracle shares the premise that the verdict is the only routing input a
    /// load decides for these rows. `testLoadCanRouteToHTMLPreview_boundsEveryLoadOutcome` pins
    /// the other load-fed input.
    func testShowsTextLoadingPlaceholder_incomingStoredPreview_showsPlaceholderExactlyWhenSomeVerdictRoutesToCard() {
        var textRows = 0
        var placeholderRows = 0
        for isNewsletter in [false, true] {
            for isLikelyCalendarInvite in [false, true] {
                for isOneToOneConversation in [false, true] {
                    for subject in Self.placeholderSubjects {
                        for senderEmail in Self.placeholderSenders {
                            let someVerdictRoutesToCard = [false, true].contains { verdict in
                                MessageDisplayPolicy.shouldShowHTMLPreview(.init(
                                    hasHTMLSource: true,
                                    isForwardedEmail: false,
                                    isNewsletter: isNewsletter,
                                    hasRichHTMLContent: verdict,
                                    isFromMe: false,
                                    isOneToOneConversation: isOneToOneConversation,
                                    subject: subject,
                                    senderEmail: senderEmail,
                                    isLikelyCalendarInvite: isLikelyCalendarInvite
                                ))
                            }
                            let showsPlaceholder = showsTextLoadingPlaceholder(
                                isFromMe: false,
                                isNewsletter: isNewsletter,
                                isLikelyCalendarInvite: isLikelyCalendarInvite,
                                isOneToOneConversation: isOneToOneConversation,
                                subject: subject,
                                senderEmail: senderEmail
                            )
                            XCTAssertEqual(
                                showsPlaceholder,
                                someVerdictRoutesToCard,
                                "newsletter=\(isNewsletter) invite=\(isLikelyCalendarInvite) "
                                    + "oneToOne=\(isOneToOneConversation) subject=\(subject ?? "nil") "
                                    + "sender=\(senderEmail ?? "nil")"
                            )
                            if showsPlaceholder {
                                placeholderRows += 1
                            } else {
                                textRows += 1
                            }
                        }
                    }
                }
            }
        }
        XCTAssertGreaterThan(textRows, 0, "no row rendered text: the comparison above proved nothing")
        XCTAssertGreaterThan(placeholderRows, 0, "no row kept the pill: the comparison above proved nothing")
    }

    /// `loadCanRouteToHTMLPreview` is an upper bound on everything a load can do to the routing.
    /// The row is asked about as it stands before the load (no rich verdict); the load can then
    /// publish either verdict and either HTML-source value, and whenever the routing cards any of
    /// those four outcomes the probe must already have said so. Forwarded and own rows are
    /// included: the probe is a standalone function.
    ///
    /// Revert-check: narrowing `MessageDisplayPolicy.loadCanRouteToHTMLPreview` to
    /// `shouldShowHTMLPreview(input)` (only the verdict the row carries) fails this test. So does
    /// a routing change that lets an HTML source card a row a rich verdict does not, which would
    /// mean the probe must enumerate that input too.
    func testLoadCanRouteToHTMLPreview_boundsEveryLoadOutcome() {
        var outcomesTheLoadAloneRoutesToCard = 0
        for hasHTMLSourceBeforeLoad in [false, true] {
            for isForwardedEmail in [false, true] {
                for isNewsletter in [false, true] {
                    for isFromMe in [false, true] {
                        for isOneToOneConversation in [false, true] {
                            for isLikelyCalendarInvite in [false, true] {
                                for subject in Self.placeholderSubjects + ["Fwd: Lunch?"] {
                                    for senderEmail in Self.placeholderSenders {
                                        func input(hasHTMLSource: Bool, hasRichHTMLContent: Bool) -> MessageDisplayInput {
                                            MessageDisplayInput(
                                                hasHTMLSource: hasHTMLSource,
                                                isForwardedEmail: isForwardedEmail,
                                                isNewsletter: isNewsletter,
                                                hasRichHTMLContent: hasRichHTMLContent,
                                                isFromMe: isFromMe,
                                                isOneToOneConversation: isOneToOneConversation,
                                                subject: subject,
                                                senderEmail: senderEmail,
                                                isLikelyCalendarInvite: isLikelyCalendarInvite
                                            )
                                        }
                                        let beforeLoad = input(
                                            hasHTMLSource: hasHTMLSourceBeforeLoad,
                                            hasRichHTMLContent: false
                                        )
                                        let routesToCardBeforeLoad = MessageDisplayPolicy.shouldShowHTMLPreview(beforeLoad)
                                        let loadCanRouteToCard = MessageDisplayPolicy.loadCanRouteToHTMLPreview(beforeLoad)
                                        for hasHTMLSource in [false, true] {
                                            for hasRichHTMLContent in [false, true] {
                                                let outcome = input(
                                                    hasHTMLSource: hasHTMLSource,
                                                    hasRichHTMLContent: hasRichHTMLContent
                                                )
                                                guard MessageDisplayPolicy.shouldShowHTMLPreview(outcome) else { continue }
                                                if !routesToCardBeforeLoad {
                                                    outcomesTheLoadAloneRoutesToCard += 1
                                                }
                                                XCTAssertTrue(
                                                    loadCanRouteToCard,
                                                    "htmlBefore=\(hasHTMLSourceBeforeLoad) forwarded=\(isForwardedEmail) "
                                                        + "newsletter=\(isNewsletter) fromMe=\(isFromMe) "
                                                        + "oneToOne=\(isOneToOneConversation) invite=\(isLikelyCalendarInvite) "
                                                        + "subject=\(subject ?? "nil") sender=\(senderEmail ?? "nil") "
                                                        + "outcome html=\(hasHTMLSource) rich=\(hasRichHTMLContent)"
                                                )
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        XCTAssertGreaterThan(
            outcomesTheLoadAloneRoutesToCard,
            0,
            "no outcome differed from the row before its load: the bound above proved nothing"
        )
    }

    /// The copy replaces the verdict and nothing else. `isLikelyCalendarInvite` is a defaulted
    /// initializer parameter, so a copy rebuilt through the initializer could drop it and still
    /// compile.
    ///
    /// Revert-check: rebuilding the copy in `MessageDisplayInput.withRichHTMLContent` through the
    /// initializer without `isLikelyCalendarInvite` fails the invite assertions.
    func testWithRichHTMLContent_replacesOnlyTheVerdict() {
        let input = MessageDisplayInput(
            hasHTMLSource: true,
            isForwardedEmail: true,
            isNewsletter: true,
            hasRichHTMLContent: false,
            isFromMe: true,
            isOneToOneConversation: true,
            subject: "Re: Dinner",
            senderEmail: "alice@example.com",
            isLikelyCalendarInvite: true
        )
        for verdict in [true, false] {
            let copy = input.withRichHTMLContent(verdict)
            XCTAssertEqual(copy.hasRichHTMLContent, verdict)
            XCTAssertTrue(copy.hasHTMLSource)
            XCTAssertTrue(copy.isForwardedEmail)
            XCTAssertTrue(copy.isNewsletter)
            XCTAssertTrue(copy.isFromMe)
            XCTAssertTrue(copy.isOneToOneConversation)
            XCTAssertEqual(copy.subject, "Re: Dinner")
            XCTAssertEqual(copy.senderEmail, "alice@example.com")
            XCTAssertTrue(copy.isLikelyCalendarInvite)
        }
    }

    /// Own rows must not consult the routing probe. It is true for an own row with a new subject
    /// in a group conversation, because the routing alone would card that row on a rich verdict;
    /// but the loader never returns that verdict for an own row with a stored preview, so the row
    /// ends as its stored text and renders it now.
    ///
    /// Revert-check: gating `rendersStoredOwnPreview` on `!loadCanRouteToHTMLPreview(routing)`, or
    /// hoisting that check above the `isFromMe` split in
    /// `MessageDisplayPolicy.showsTextLoadingPlaceholder`, fails the first assertion.
    func testShowsTextLoadingPlaceholder_ownStoredPreviewInGroupConversation_ignoresRoutingProbe() {
        XCTAssertFalse(showsTextLoadingPlaceholder(isOneToOneConversation: false, subject: "Agenda"))
        XCTAssertTrue(
            MessageDisplayPolicy.loadCanRouteToHTMLPreview(.init(
                hasHTMLSource: true,
                isForwardedEmail: false,
                isNewsletter: false,
                hasRichHTMLContent: false,
                isFromMe: true,
                isOneToOneConversation: false,
                subject: "Agenda",
                senderEmail: nil
            )),
            "the probe says a load could card this row, which is why own rows must not ask it"
        )
    }

    /// Forwarded rows wait for the structured forward summary whatever text they store, HTML
    /// source or not.
    ///
    /// Revert-check: deleting the `if routing.isForwardedEmail { return true }` early return in
    /// `MessageDisplayPolicy.showsTextLoadingPlaceholder`, or moving it below the HTML-source
    /// guard, fails the second assertion. (The first also holds through the routing probe, which
    /// cards an incoming forward.)
    func testShowsTextLoadingPlaceholder_incomingForwardedWithStoredPreview_showsPlaceholder() {
        XCTAssertTrue(showsTextLoadingPlaceholder(isForwardedEmail: true, isFromMe: false))
        XCTAssertTrue(showsTextLoadingPlaceholder(hasHTMLSource: false, isForwardedEmail: true, isFromMe: false))
    }

    /// A blank stored preview is no stored preview: the row has no final text to show yet. Pinned
    /// on a reply, the row class that would otherwise render its stored text.
    ///
    /// Revert-check: testing `chatPreviewText != nil` instead of
    /// `MessagePreviewText.nonEmpty(chatPreviewText) != nil` in the incoming-row branch of
    /// `MessageDisplayPolicy.showsTextLoadingPlaceholder` fails this test.
    func testShowsTextLoadingPlaceholder_incomingWithBlankStoredPreview_showsPlaceholder() {
        XCTAssertTrue(showsTextLoadingPlaceholder(isFromMe: false, subject: "Re: Dinner", chatPreviewText: ""))
        XCTAssertTrue(showsTextLoadingPlaceholder(isFromMe: false, subject: "Re: Dinner", chatPreviewText: " \n\t "))
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
    /// stored preview still waits for content detection, reply or not; an incoming row the load
    /// can still route to a card waits whatever it stores; and forwarded, newsletter and invite
    /// rows of the user's own can still route elsewhere, whatever attachments they carry.
    func testShowsTextLoadingPlaceholder_attachmentsOnIncomingForwardedNewsletterOrInvite_showsPlaceholder() {
        XCTAssertTrue(showsTextLoadingPlaceholder(isFromMe: false, chatPreviewText: nil, hasDisplayableAttachments: true))
        XCTAssertTrue(
            showsTextLoadingPlaceholder(
                isFromMe: false,
                subject: "Re: Dinner",
                chatPreviewText: nil,
                hasDisplayableAttachments: true
            )
        )
        XCTAssertTrue(showsTextLoadingPlaceholder(isFromMe: false, subject: "Photos", hasDisplayableAttachments: true))
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

    /// A row with no HTML source that is not forwarded never shows the pill, and no loaded row
    /// does. That holds for an incoming row with a new subject too, which the routing probe says a
    /// load could card. The load can still card such a row from HTML embedded in its body text
    /// (the policy's "one path this does not close"), but waiting on that would put the pill on
    /// every plain-text message that starts a thread. Forwarded rows are the exception, pinned
    /// above.
    ///
    /// Revert-check: moving the `guard routing.hasHTMLSource` in
    /// `MessageDisplayPolicy.showsTextLoadingPlaceholder` below the incoming-row branch fails the
    /// first and third assertions; moving the `guard !hasLoadedContent` below the incoming-row
    /// branch fails the second, fourth and fifth (the fourth as soon as it sits below the
    /// forwarded early return).
    func testShowsTextLoadingPlaceholder_withoutHTMLSourceOrOnceLoaded_rendersText() {
        XCTAssertFalse(showsTextLoadingPlaceholder(hasHTMLSource: false, isFromMe: false, chatPreviewText: nil))
        XCTAssertFalse(showsTextLoadingPlaceholder(hasLoadedContent: true, isFromMe: false, chatPreviewText: nil))
        XCTAssertFalse(showsTextLoadingPlaceholder(hasHTMLSource: false, isFromMe: false, subject: "Lunch?"))
        XCTAssertFalse(showsTextLoadingPlaceholder(hasLoadedContent: true, isForwardedEmail: true))
        XCTAssertFalse(showsTextLoadingPlaceholder(hasLoadedContent: true, isFromMe: false, subject: "Lunch?"))
    }

    // MARK: - Pre-publish state (a fresh mount's first pass)

    private enum PrePublishPresentation: Equatable {
        case previewCard
        case loadingPlaceholder
        case text
    }

    /// What a non-forwarded row presents on a fresh mount's first body pass: the two view
    /// decisions (`MessageBubble.showHTMLPreview`, then `MessageContentView.textContent`) taken
    /// from a view model created the way `MessageBubble.init` creates it, before any load has
    /// run. The defaults describe an incoming HTML row with a stored preview.
    @MainActor
    private func prePublishPresentation(
        hasHTMLSource: Bool = true,
        isFromMe: Bool = false,
        isLikelyCalendarInvite: Bool = false,
        subject: String?,
        chatPreviewText: String? = "Stored preview"
    ) -> PrePublishPresentation {
        let viewModel = MessageBubbleViewModel(
            loader: MockMessageBubbleLoader(senderResults: [], contentResults: []),
            initialHasHTMLSource: hasHTMLSource
        )
        let routing = MessageDisplayInput(
            hasHTMLSource: viewModel.htmlAnalysis.hasHTMLSource,
            isForwardedEmail: false,
            isNewsletter: false,
            hasRichHTMLContent: viewModel.hasRichHTMLContent,
            isFromMe: isFromMe,
            isOneToOneConversation: true,
            subject: subject,
            senderEmail: "alice@example.com",
            isLikelyCalendarInvite: isLikelyCalendarInvite
        )
        if MessageDisplayPolicy.shouldShowHTMLPreview(routing) {
            return .previewCard
        }
        return MessageDisplayPolicy.showsTextLoadingPlaceholder(
            hasLoadedContent: viewModel.hasLoadedContent,
            routing: routing,
            chatPreviewText: chatPreviewText,
            hasDisplayableAttachments: false
        ) ? .loadingPlaceholder : .text
    }

    /// A fresh mount's first body pass runs before the bubble's load has published anything. The
    /// view model is created with the row's HTML-source hint, so that pass presents an HTML row
    /// as every later pre-load pass does: the pill where the load still decides the text or the
    /// routing, the card where the routing needs no verdict. Unseeded, every pass before the load
    /// began was asked about a row with no HTML source and laid out text for each of these (text
    /// → pill or card); on a chat open, inside the hidden initial-anchor pass.
    ///
    /// The invite cards on that pass while the load has yet to say whether the calendar card is
    /// supported, so its subject line shows above the card until then, as it does mid-load.
    ///
    /// Revert-check: seeding `htmlAnalysis` with `.empty` in `MessageBubbleViewModel.init`
    /// (ignoring `initialHasHTMLSource`) turns every assertion here into `.text`.
    ///
    /// HONEST SCOPE: `prePublishPresentation` mirrors the two view decisions and seeds the view
    /// model by hand. That `MessageBubble.init` passes `message.hasHTMLSource` is view wiring;
    /// there is no UI test target to cover it.
    @MainActor
    func testPrePublishState_htmlRowTheLoadStillDecides_isPillOrCardNotText() {
        XCTAssertEqual(prePublishPresentation(subject: "Your receipt"), .loadingPlaceholder)
        XCTAssertEqual(prePublishPresentation(subject: "Re: Dinner", chatPreviewText: nil), .loadingPlaceholder)
        XCTAssertEqual(
            prePublishPresentation(isFromMe: true, subject: "Re: Dinner", chatPreviewText: nil),
            .loadingPlaceholder
        )
        XCTAssertEqual(
            prePublishPresentation(isLikelyCalendarInvite: true, subject: "Invitation: Lunch"),
            .previewCard
        )
    }

    /// The rows a first pass still renders as text. A reply's or an own row's stored preview is
    /// its final text, HTML source or not. A row with no HTML-source hint is seeded as such and
    /// takes the policy's one unclosed path, new subject and invite flag included: the seed is
    /// the row's own hint, never a guess that a row has HTML.
    ///
    /// Revert-check: seeding `htmlAnalysis` with `.placeholder(hasHTMLSource: true)` whatever the
    /// hint in `MessageBubbleViewModel.init` fails the last two assertions (the pill, and the
    /// card).
    @MainActor
    func testPrePublishState_finalStoredTextOrNoHTMLSourceHint_isText() {
        XCTAssertEqual(prePublishPresentation(subject: "Re: Dinner"), .text)
        XCTAssertEqual(prePublishPresentation(isFromMe: true, subject: "Re: Dinner"), .text)
        XCTAssertEqual(prePublishPresentation(hasHTMLSource: false, subject: "Lunch?"), .text)
        XCTAssertEqual(
            prePublishPresentation(hasHTMLSource: false, isLikelyCalendarInvite: true, subject: "Invitation: Lunch"),
            .text
        )
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
