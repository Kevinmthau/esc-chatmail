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
    ///
    /// `knownRichVerdict` nil is a row whose verdict only its load can decide: the routing input
    /// carries not-rich and `richVerdictIsKnown` is false, which was every row before verdicts
    /// were stored. Non-nil is a row carrying that verdict as known. The pair is built by hand,
    /// not through `MessageDisplayPolicy.resolvedRichVerdict`, so these tests do not lean on it.
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
        hasDisplayableAttachments: Bool = false,
        knownRichVerdict: Bool? = nil
    ) -> Bool {
        MessageDisplayPolicy.showsTextLoadingPlaceholder(
            hasLoadedContent: hasLoadedContent,
            routing: MessageDisplayInput(
                hasHTMLSource: hasHTMLSource,
                isForwardedEmail: isForwardedEmail,
                isNewsletter: isNewsletter,
                hasRichHTMLContent: knownRichVerdict ?? false,
                isFromMe: isFromMe,
                isOneToOneConversation: isOneToOneConversation,
                subject: subject,
                senderEmail: senderEmail,
                isLikelyCalendarInvite: isLikelyCalendarInvite
            ),
            richVerdictIsKnown: knownRichVerdict != nil,
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
    /// "rich" (a receipt, a notification), so while that verdict is unknown its stored preview is
    /// not yet known to be its final rendering. Rendering it showed the stored text and then
    /// swapped it for the card.
    ///
    /// Revert-check: replacing
    /// `!loadCanRouteToHTMLPreview(routing, richVerdictIsKnown: richVerdictIsKnown)` in
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

    /// The whole rule for an incoming HTML row with a stored preview and an unknown verdict, both
    /// directions at once: the pill shows exactly when the routing sends the row to a card for
    /// some rich-content verdict. The oracle builds each outcome with the full initializer, so it
    /// does not share `MessageDisplayInput.withRichHTMLContent` with the code under test. Trusted
    /// senders are included although the content view never asks about them (the routing cards
    /// them before the load): a direct call must still never answer "text" for one.
    ///
    /// Revert-check: the superseded flag list in `rendersStoredIncomingPreview` fails in both
    /// directions (text for a new-subject row the rich outcome cards; the pill for a one-to-one
    /// newsletter or invite reply no outcome cards). Narrowing the unknown-verdict form of
    /// `MessageDisplayPolicy.loadCanRouteToHTMLPreview` to `shouldShowHTMLPreview(input)` (what
    /// the known form asks) fails the first direction.
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

    /// With an unknown verdict, `loadCanRouteToHTMLPreview` is an upper bound on everything a load
    /// can do to the routing. The row is asked about as it stands before the load (no rich
    /// verdict); the load can then publish either verdict and either HTML-source value, and
    /// whenever the routing cards any of those four outcomes the probe must already have said so.
    /// Forwarded and own rows are included: the probe is a standalone function.
    ///
    /// Revert-check: narrowing the unknown-verdict form of
    /// `MessageDisplayPolicy.loadCanRouteToHTMLPreview` to `shouldShowHTMLPreview(input)` (only
    /// the verdict the row carries, which is what the known form asks) fails this test. So does
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
                                        let loadCanRouteToCard = MessageDisplayPolicy.loadCanRouteToHTMLPreview(
                                            beforeLoad,
                                            richVerdictIsKnown: false
                                        )
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
    /// Revert-check: gating `rendersStoredOwnPreview` on
    /// `!loadCanRouteToHTMLPreview(routing, richVerdictIsKnown: richVerdictIsKnown)`, or hoisting
    /// that check above the `isFromMe` split in
    /// `MessageDisplayPolicy.showsTextLoadingPlaceholder`, fails the first assertion.
    func testShowsTextLoadingPlaceholder_ownStoredPreviewInGroupConversation_ignoresRoutingProbe() {
        XCTAssertFalse(showsTextLoadingPlaceholder(isOneToOneConversation: false, subject: "Agenda"))
        XCTAssertTrue(
            MessageDisplayPolicy.loadCanRouteToHTMLPreview(
                .init(
                    hasHTMLSource: true,
                    isForwardedEmail: false,
                    isNewsletter: false,
                    hasRichHTMLContent: false,
                    isFromMe: true,
                    isOneToOneConversation: false,
                    subject: "Agenda",
                    senderEmail: nil
                ),
                richVerdictIsKnown: false
            ),
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
    /// (the policy's "two paths this does not close"), but waiting on that would put the pill on
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

    // MARK: - Text loading placeholder, known rich-content verdict

    /// The row a stored verdict exists for: an incoming HTML row with a stored preview and a
    /// subject that is not a reply, not flagged newsletter or invite, from an ordinary sender.
    /// Unknown, a rich verdict could still route it to the card, so it waited on the pill; known
    /// not-rich, the load can only confirm its stored preview, so it renders now. Conversation
    /// kind, an ordinary sender address and displayed attachments change nothing.
    ///
    /// Revert-check: ignoring `richVerdictIsKnown` in
    /// `MessageDisplayPolicy.loadCanRouteToHTMLPreview` (trying `[false, true]` whatever it says)
    /// puts the pill back and fails every `XCTAssertFalse` here. The `XCTAssertTrue` in the loop
    /// is the premise: the same row with an unknown verdict keeps the pill, so the known verdict
    /// is what changed the answer.
    ///
    /// HONEST SCOPE: this pins the decision. That `MessageBubble` hands `MessageContentView` the
    /// known-ness from the resolution that built its `displayInput` is view wiring; there is no
    /// UI test target to cover it.
    func testShowsTextLoadingPlaceholder_incomingStoredPreviewKnownNotRich_rendersText() {
        for subject in [nil, "", "Your receipt"] as [String?] {
            for isOneToOneConversation in [true, false] {
                let row = "subject=\(subject ?? "nil") oneToOne=\(isOneToOneConversation)"
                XCTAssertFalse(
                    showsTextLoadingPlaceholder(
                        isFromMe: false,
                        isOneToOneConversation: isOneToOneConversation,
                        subject: subject,
                        knownRichVerdict: false
                    ),
                    row
                )
                XCTAssertTrue(
                    showsTextLoadingPlaceholder(
                        isFromMe: false,
                        isOneToOneConversation: isOneToOneConversation,
                        subject: subject
                    ),
                    "unknown verdict: \(row)"
                )
            }
        }
        XCTAssertFalse(
            showsTextLoadingPlaceholder(
                isFromMe: false,
                subject: "Your receipt",
                senderEmail: "alice@example.com",
                knownRichVerdict: false
            )
        )
        XCTAssertFalse(
            showsTextLoadingPlaceholder(
                isFromMe: false,
                subject: "Your receipt",
                hasDisplayableAttachments: true,
                knownRichVerdict: false
            )
        )
    }

    /// A known verdict is not a stored preview. A row with no stored text has nothing final to
    /// show whatever its verdict, so it waits on the pill like any incoming HTML row without one.
    ///
    /// Revert-check: dropping the `MessagePreviewText.nonEmpty(chatPreviewText) != nil` term from
    /// `rendersStoredIncomingPreview` in `MessageDisplayPolicy.showsTextLoadingPlaceholder` (a
    /// known verdict alone rendering the row) fails this for every row here the routing does not
    /// card: the reply for either verdict, the new subject when not rich.
    ///
    /// HONEST SCOPE: the view does not ask this before a load. A blank-preview row's stored
    /// verdict is reported as unknown (`ChatMessageRowModelMapper.knownRichContentVerdict`), so
    /// this pins the policy for a direct call only.
    func testShowsTextLoadingPlaceholder_incomingKnownVerdictWithBlankStoredPreview_showsPlaceholder() {
        for knownRichVerdict in [false, true] {
            for subject in ["Your receipt", "Re: Dinner"] {
                for chatPreviewText in [nil, "", " \n\t "] as [String?] {
                    XCTAssertTrue(
                        showsTextLoadingPlaceholder(
                            isFromMe: false,
                            subject: subject,
                            chatPreviewText: chatPreviewText,
                            knownRichVerdict: knownRichVerdict
                        ),
                        "known=\(knownRichVerdict) subject=\(subject)"
                    )
                }
            }
        }
    }

    /// The whole rule for an incoming HTML row with a stored preview once its verdict is known,
    /// over the matrix the unknown-verdict oracle uses and both verdicts: the pill shows exactly
    /// when the routing cards the row for the verdict it carries. The content view never asks
    /// about those rows (the bubble shows the card), so in the view a known row with a stored
    /// preview always renders it; a direct call must still never answer "text" for a row the
    /// routing cards. The oracle builds its input with the full initializer, so it does not share
    /// `MessageDisplayInput.withRichHTMLContent` with the code under test.
    ///
    /// Knowing the verdict only ever removes a pill: no row gets one that the unknown rule
    /// rendered as text.
    ///
    /// Revert-check: ignoring `richVerdictIsKnown` in
    /// `MessageDisplayPolicy.loadCanRouteToHTMLPreview` (trying both verdicts) keeps the pill on
    /// known not-rich rows only a rich verdict would card: the comparison fails and
    /// `rowsTheKnownVerdictFreedFromThePill` stays zero. Asking the known form about a fixed
    /// verdict instead of `input.hasRichHTMLContent` fails the comparison for the other verdict.
    ///
    /// HONEST SCOPE: the oracle takes the premise of a known verdict as given, that the load
    /// publishes the verdict the row carries. A stale stored verdict breaks it, and is handled
    /// outside this decision (`resolvedRichVerdict` lets the load win).
    func testShowsTextLoadingPlaceholder_incomingStoredPreviewKnownVerdict_showsPlaceholderExactlyWhenItsVerdictRoutesToCard() {
        var textRows = 0
        var placeholderRows = 0
        var rowsTheKnownVerdictFreedFromThePill = 0
        for knownRichVerdict in [false, true] {
            for isNewsletter in [false, true] {
                for isLikelyCalendarInvite in [false, true] {
                    for isOneToOneConversation in [false, true] {
                        for subject in Self.placeholderSubjects {
                            for senderEmail in Self.placeholderSenders {
                                let row = "known=\(knownRichVerdict) newsletter=\(isNewsletter) "
                                    + "invite=\(isLikelyCalendarInvite) oneToOne=\(isOneToOneConversation) "
                                    + "subject=\(subject ?? "nil") sender=\(senderEmail ?? "nil")"
                                let itsVerdictRoutesToCard = MessageDisplayPolicy.shouldShowHTMLPreview(.init(
                                    hasHTMLSource: true,
                                    isForwardedEmail: false,
                                    isNewsletter: isNewsletter,
                                    hasRichHTMLContent: knownRichVerdict,
                                    isFromMe: false,
                                    isOneToOneConversation: isOneToOneConversation,
                                    subject: subject,
                                    senderEmail: senderEmail,
                                    isLikelyCalendarInvite: isLikelyCalendarInvite
                                ))
                                let showsPlaceholder = showsTextLoadingPlaceholder(
                                    isFromMe: false,
                                    isNewsletter: isNewsletter,
                                    isLikelyCalendarInvite: isLikelyCalendarInvite,
                                    isOneToOneConversation: isOneToOneConversation,
                                    subject: subject,
                                    senderEmail: senderEmail,
                                    knownRichVerdict: knownRichVerdict
                                )
                                let showsPlaceholderWhileUnknown = showsTextLoadingPlaceholder(
                                    isFromMe: false,
                                    isNewsletter: isNewsletter,
                                    isLikelyCalendarInvite: isLikelyCalendarInvite,
                                    isOneToOneConversation: isOneToOneConversation,
                                    subject: subject,
                                    senderEmail: senderEmail
                                )
                                XCTAssertEqual(showsPlaceholder, itsVerdictRoutesToCard, row)
                                if showsPlaceholder {
                                    placeholderRows += 1
                                    XCTAssertTrue(showsPlaceholderWhileUnknown, "a known verdict added a pill: \(row)")
                                } else {
                                    textRows += 1
                                    if showsPlaceholderWhileUnknown {
                                        rowsTheKnownVerdictFreedFromThePill += 1
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        XCTAssertGreaterThan(textRows, 0, "no row rendered text: the comparison above proved nothing")
        XCTAssertGreaterThan(placeholderRows, 0, "no row kept the pill: the comparison above proved nothing")
        XCTAssertGreaterThan(
            rowsTheKnownVerdictFreedFromThePill,
            0,
            "no row differed from the unknown rule: the known form was never exercised"
        )
    }

    /// The known form of `loadCanRouteToHTMLPreview` bounds what a load can do to a row whose
    /// HTML-source hint is already true. A load only upgrades the hint and, by the premise of a
    /// known verdict, publishes the verdict the row carries, so the one outcome left is the row
    /// as asked: the probe must say "card" whenever the routing cards it, and (the reason to know
    /// the verdict at all) must not say it otherwise. Forwarded and own rows are included: the
    /// probe is a standalone function.
    ///
    /// Revert-check: asking the known form of `MessageDisplayPolicy.loadCanRouteToHTMLPreview`
    /// about a fixed verdict (`[false]`) instead of `input.hasRichHTMLContent` fails the bound
    /// for a known rich row; ignoring `richVerdictIsKnown` (trying both verdicts) fails the
    /// tightness assertion for a known not-rich row and leaves `rowsTheKnownFormNarrowed` zero.
    ///
    /// HONEST SCOPE: scoped to `hasHTMLSource == true`, the only place
    /// `showsTextLoadingPlaceholder` asks the probe. The known form does not bound a
    /// `hasHTMLSource` upgrade (see the doc comment on `loadCanRouteToHTMLPreview`): asked about
    /// a known not-rich row whose hint is still false, it answers false although an upgraded hint
    /// can card the row. The closing assertions record that gap on a calendar invite, so the
    /// scope here is not read as an oversight: a caller that asks the known form ahead of the
    /// HTML-source guard must enumerate the upgrade first, and this bound then widens to a false
    /// hint. Nor is the premise itself tested here (see the oracle above).
    func testLoadCanRouteToHTMLPreview_knownVerdictWithHTMLSource_boundsTheLoadOutcome() {
        var outcomesRoutedToCard = 0
        var rowsTheKnownFormNarrowed = 0
        for knownRichVerdict in [false, true] {
            for isForwardedEmail in [false, true] {
                for isNewsletter in [false, true] {
                    for isFromMe in [false, true] {
                        for isOneToOneConversation in [false, true] {
                            for isLikelyCalendarInvite in [false, true] {
                                for subject in Self.placeholderSubjects + ["Fwd: Lunch?"] {
                                    for senderEmail in Self.placeholderSenders {
                                        let row = MessageDisplayInput(
                                            hasHTMLSource: true,
                                            isForwardedEmail: isForwardedEmail,
                                            isNewsletter: isNewsletter,
                                            hasRichHTMLContent: knownRichVerdict,
                                            isFromMe: isFromMe,
                                            isOneToOneConversation: isOneToOneConversation,
                                            subject: subject,
                                            senderEmail: senderEmail,
                                            isLikelyCalendarInvite: isLikelyCalendarInvite
                                        )
                                        let loadCanRouteToCard = MessageDisplayPolicy.loadCanRouteToHTMLPreview(
                                            row,
                                            richVerdictIsKnown: true
                                        )
                                        let unknownFormRoutesToCard = MessageDisplayPolicy.loadCanRouteToHTMLPreview(
                                            row,
                                            richVerdictIsKnown: false
                                        )
                                        let rowDescription = "known=\(knownRichVerdict) forwarded=\(isForwardedEmail) "
                                            + "newsletter=\(isNewsletter) fromMe=\(isFromMe) "
                                            + "oneToOne=\(isOneToOneConversation) invite=\(isLikelyCalendarInvite) "
                                            + "subject=\(subject ?? "nil") sender=\(senderEmail ?? "nil")"
                                        if MessageDisplayPolicy.shouldShowHTMLPreview(row) {
                                            outcomesRoutedToCard += 1
                                            XCTAssertTrue(loadCanRouteToCard, "bound: \(rowDescription)")
                                        } else {
                                            XCTAssertFalse(loadCanRouteToCard, "tightness: \(rowDescription)")
                                        }
                                        if unknownFormRoutesToCard, !loadCanRouteToCard {
                                            rowsTheKnownFormNarrowed += 1
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        XCTAssertGreaterThan(outcomesRoutedToCard, 0, "no outcome routed to a card: the bound above proved nothing")
        XCTAssertGreaterThan(
            rowsTheKnownFormNarrowed,
            0,
            "the known form never answered differently from the unknown one: tightness proved nothing"
        )

        // The gap the scope note names: a known not-rich invite whose hint has not arrived.
        func invite(hasHTMLSource: Bool) -> MessageDisplayInput {
            MessageDisplayInput(
                hasHTMLSource: hasHTMLSource,
                isForwardedEmail: false,
                isNewsletter: false,
                hasRichHTMLContent: false,
                isFromMe: false,
                isOneToOneConversation: true,
                subject: "Invitation: Board sync",
                senderEmail: "alice@example.com",
                isLikelyCalendarInvite: true
            )
        }
        XCTAssertFalse(
            MessageDisplayPolicy.loadCanRouteToHTMLPreview(invite(hasHTMLSource: false), richVerdictIsKnown: true),
            "the known form now covers a hint upgrade: widen the bound above to a false hint and drop this"
        )
        XCTAssertTrue(
            MessageDisplayPolicy.shouldShowHTMLPreview(invite(hasHTMLSource: true)),
            "the upgraded hint cards the row the known form said no load could card"
        )
        XCTAssertTrue(
            MessageDisplayPolicy.loadCanRouteToHTMLPreview(invite(hasHTMLSource: false), richVerdictIsKnown: false),
            "the unknown form covers the same upgrade through the rich verdict"
        )
    }

    /// A known verdict changes the answer only for incoming rows that are not forwards.
    /// Forwarded rows still wait for the load, which decides their rendering (the forward
    /// summary, or the card), and own rows still never consult the routing probe, whichever
    /// verdict is known.
    ///
    /// Revert-check: gating the `if routing.isForwardedEmail { return true }` early return in
    /// `MessageDisplayPolicy.showsTextLoadingPlaceholder` on `!richVerdictIsKnown` fails the
    /// forwarded assertions that have no HTML source and the own forwarded ones (an incoming
    /// forward with an HTML source still gets the pill through the probe). Routing own rows
    /// through `loadCanRouteToHTMLPreview` once the verdict is known fails the group-conversation
    /// assertion for a known rich verdict, which the closing assertion shows the probe would
    /// card.
    ///
    /// HONEST SCOPE: the view does not ask about these rows with a known verdict. The mapper
    /// reports an own or forwarded row's stored verdict as unknown
    /// (`ChatMessageRowModelMapper.knownRichContentVerdict`), and a verdict known from a published
    /// load arrives with `hasLoadedContent`, which ends the pill first. This pins the policy for
    /// direct calls.
    func testShowsTextLoadingPlaceholder_forwardedAndOwnRows_ignoreKnownVerdict() {
        for knownRichVerdict in [false, true] {
            let verdict = "known=\(knownRichVerdict)"
            XCTAssertTrue(
                showsTextLoadingPlaceholder(isForwardedEmail: true, isFromMe: false, knownRichVerdict: knownRichVerdict),
                verdict
            )
            XCTAssertTrue(
                showsTextLoadingPlaceholder(
                    hasHTMLSource: false,
                    isForwardedEmail: true,
                    isFromMe: false,
                    knownRichVerdict: knownRichVerdict
                ),
                verdict
            )
            XCTAssertTrue(showsTextLoadingPlaceholder(isForwardedEmail: true, knownRichVerdict: knownRichVerdict), verdict)
            XCTAssertTrue(
                showsTextLoadingPlaceholder(hasHTMLSource: false, isForwardedEmail: true, knownRichVerdict: knownRichVerdict),
                verdict
            )

            XCTAssertFalse(showsTextLoadingPlaceholder(knownRichVerdict: knownRichVerdict), verdict)
            XCTAssertFalse(
                showsTextLoadingPlaceholder(
                    isOneToOneConversation: false,
                    subject: "Agenda",
                    knownRichVerdict: knownRichVerdict
                ),
                verdict
            )
            XCTAssertTrue(showsTextLoadingPlaceholder(chatPreviewText: nil, knownRichVerdict: knownRichVerdict), verdict)
            XCTAssertFalse(
                showsTextLoadingPlaceholder(
                    chatPreviewText: nil,
                    hasDisplayableAttachments: true,
                    knownRichVerdict: knownRichVerdict
                ),
                verdict
            )
            XCTAssertTrue(showsTextLoadingPlaceholder(isNewsletter: true, knownRichVerdict: knownRichVerdict), verdict)
            XCTAssertTrue(
                showsTextLoadingPlaceholder(isLikelyCalendarInvite: true, knownRichVerdict: knownRichVerdict),
                verdict
            )
        }
        XCTAssertTrue(
            MessageDisplayPolicy.loadCanRouteToHTMLPreview(
                .init(
                    hasHTMLSource: true,
                    isForwardedEmail: false,
                    isNewsletter: false,
                    hasRichHTMLContent: true,
                    isFromMe: true,
                    isOneToOneConversation: false,
                    subject: "Agenda",
                    senderEmail: nil
                ),
                richVerdictIsKnown: true
            ),
            "the known form cards this own row on a rich verdict, which is why own rows must not ask it"
        )
    }

    /// Once the load has published, the bubble's verdict is always known (`resolvedRichVerdict`),
    /// so this is the combination every loaded row is asked with: no pill, whatever the verdict,
    /// the stored preview or the row kind.
    ///
    /// Revert-check: moving the `guard !hasLoadedContent` in
    /// `MessageDisplayPolicy.showsTextLoadingPlaceholder` below the incoming-row branch fails the
    /// first assertion (the known form cards a rich new-subject row) and the third (no stored
    /// preview); below the forwarded early return alone, the fourth.
    func testShowsTextLoadingPlaceholder_onceLoadedWithKnownVerdict_rendersText() {
        XCTAssertFalse(
            showsTextLoadingPlaceholder(hasLoadedContent: true, isFromMe: false, subject: "Lunch?", knownRichVerdict: true)
        )
        XCTAssertFalse(
            showsTextLoadingPlaceholder(hasLoadedContent: true, isFromMe: false, subject: "Lunch?", knownRichVerdict: false)
        )
        XCTAssertFalse(
            showsTextLoadingPlaceholder(
                hasLoadedContent: true,
                isFromMe: false,
                subject: "Lunch?",
                chatPreviewText: nil,
                knownRichVerdict: false
            )
        )
        XCTAssertFalse(
            showsTextLoadingPlaceholder(hasLoadedContent: true, isForwardedEmail: true, knownRichVerdict: false)
        )
    }

    // MARK: - Resolved rich-content verdict

    /// Once the load has published, its verdict is the row's and is known, whatever the row
    /// stores: a stored verdict that disagrees is stale (the load evaluates the same rule over
    /// the row's current state), and a row with no stored verdict has just learned its own.
    ///
    /// Revert-check: testing `knownStoredVerdict` ahead of `hasLoadedContent` in
    /// `MessageDisplayPolicy.resolvedRichVerdict` fails the first two assertions; deriving
    /// `isKnown` from the stored verdict alone (`knownStoredVerdict != nil`) fails the last two.
    func testResolvedRichVerdict_onceLoaded_loadedVerdictWinsOverStored() {
        XCTAssertEqual(
            MessageDisplayPolicy.resolvedRichVerdict(
                hasLoadedContent: true,
                loadedHasRichHTMLContent: true,
                knownStoredVerdict: false
            ),
            MessageDisplayPolicy.ResolvedRichVerdict(hasRichHTMLContent: true, isKnown: true)
        )
        XCTAssertEqual(
            MessageDisplayPolicy.resolvedRichVerdict(
                hasLoadedContent: true,
                loadedHasRichHTMLContent: false,
                knownStoredVerdict: true
            ),
            MessageDisplayPolicy.ResolvedRichVerdict(hasRichHTMLContent: false, isKnown: true)
        )
        XCTAssertEqual(
            MessageDisplayPolicy.resolvedRichVerdict(
                hasLoadedContent: true,
                loadedHasRichHTMLContent: true,
                knownStoredVerdict: nil
            ),
            MessageDisplayPolicy.ResolvedRichVerdict(hasRichHTMLContent: true, isKnown: true)
        )
        XCTAssertEqual(
            MessageDisplayPolicy.resolvedRichVerdict(
                hasLoadedContent: true,
                loadedHasRichHTMLContent: false,
                knownStoredVerdict: nil
            ),
            MessageDisplayPolicy.ResolvedRichVerdict(hasRichHTMLContent: false, isKnown: true)
        )
    }

    /// Until the load has published, the stored verdict is the row's and is known. The view
    /// model's verdict is not consulted: it is the default false, or a value no load has
    /// published for this row.
    ///
    /// Revert-check: dropping the `if let knownStoredVerdict` branch from
    /// `MessageDisplayPolicy.resolvedRichVerdict` fails all four assertions (unknown, not rich);
    /// returning `loadedHasRichHTMLContent` from it fails the first and third.
    func testResolvedRichVerdict_beforeLoad_usesStoredVerdict() {
        XCTAssertEqual(
            MessageDisplayPolicy.resolvedRichVerdict(
                hasLoadedContent: false,
                loadedHasRichHTMLContent: false,
                knownStoredVerdict: true
            ),
            MessageDisplayPolicy.ResolvedRichVerdict(hasRichHTMLContent: true, isKnown: true)
        )
        XCTAssertEqual(
            MessageDisplayPolicy.resolvedRichVerdict(
                hasLoadedContent: false,
                loadedHasRichHTMLContent: false,
                knownStoredVerdict: false
            ),
            MessageDisplayPolicy.ResolvedRichVerdict(hasRichHTMLContent: false, isKnown: true)
        )
        XCTAssertEqual(
            MessageDisplayPolicy.resolvedRichVerdict(
                hasLoadedContent: false,
                loadedHasRichHTMLContent: true,
                knownStoredVerdict: false
            ),
            MessageDisplayPolicy.ResolvedRichVerdict(hasRichHTMLContent: false, isKnown: true)
        )
        XCTAssertEqual(
            MessageDisplayPolicy.resolvedRichVerdict(
                hasLoadedContent: false,
                loadedHasRichHTMLContent: true,
                knownStoredVerdict: true
            ),
            MessageDisplayPolicy.ResolvedRichVerdict(hasRichHTMLContent: true, isKnown: true)
        )
    }

    /// A row with no stored verdict that has not loaded routes as not rich and says so: unknown.
    /// The flag is what keeps the pill on a row a rich verdict could still card; reported as
    /// known, the bubble would render the stored text and then swap it for the card.
    ///
    /// Revert-check: reporting the fall-through of `MessageDisplayPolicy.resolvedRichVerdict` as
    /// known (`isKnown: true`) fails both assertions; returning `loadedHasRichHTMLContent` from
    /// it fails the second.
    func testResolvedRichVerdict_notLoadedAndNoStoredVerdict_isUnknownAndNotRich() {
        XCTAssertEqual(
            MessageDisplayPolicy.resolvedRichVerdict(
                hasLoadedContent: false,
                loadedHasRichHTMLContent: false,
                knownStoredVerdict: nil
            ),
            MessageDisplayPolicy.ResolvedRichVerdict(hasRichHTMLContent: false, isKnown: false)
        )
        XCTAssertEqual(
            MessageDisplayPolicy.resolvedRichVerdict(
                hasLoadedContent: false,
                loadedHasRichHTMLContent: true,
                knownStoredVerdict: nil
            ),
            MessageDisplayPolicy.ResolvedRichVerdict(hasRichHTMLContent: false, isKnown: false)
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
