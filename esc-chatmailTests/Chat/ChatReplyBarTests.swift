import XCTest
@testable import esc_chatmail

@MainActor
final class ChatReplyBarTests: XCTestCase {
    func testRemovedAttachmentPlaceholderSkipsOnlyThatImport() {
        XCTAssertEqual(
            AttachmentImportFinalizationResult.resolve(
                didFinalize: false,
                generationIsActive: true
            ),
            .placeholderRemoved
        )
    }

    func testCancelledAttachmentImportStopsTheBatch() {
        XCTAssertEqual(
            AttachmentImportFinalizationResult.resolve(
                didFinalize: false,
                generationIsActive: false
            ),
            .cancelled
        )
    }

    func testFinalizedAttachmentContinuesTheBatch() {
        XCTAssertEqual(
            AttachmentImportFinalizationResult.resolve(
                didFinalize: true,
                generationIsActive: false
            ),
            .finalized
        )
    }

    func testSendIsDisabledWhileSelectedAttachmentIsStillProcessing() {
        XCTAssertFalse(
            ChatReplyBar.isSendEnabled(
                replyText: "Ready to send",
                hasAttachments: false,
                isSending: false,
                isProcessingAttachments: true
            )
        )
    }

    func testSendIsEnabledAfterSelectedAttachmentFinishesProcessing() {
        XCTAssertTrue(
            ChatReplyBar.isSendEnabled(
                replyText: "Ready to send",
                hasAttachments: false,
                isSending: false,
                isProcessingAttachments: false
            )
        )
    }

    func testSendIsDisabledWhileReplyPreflightIsActive() {
        XCTAssertFalse(
            ChatReplyBar.isSendEnabled(
                replyText: "Ready to send",
                hasAttachments: false,
                isSending: true,
                isProcessingAttachments: false
            )
        )
    }

    /// The whole bar used to be `.disabled(isSending)`, and SwiftUI takes
    /// focus from a disabled field: the keyboard dropped on every send.
    ///
    /// Revert-check: making `ChatReplyBarControlPolicy.isTextFieldEnabled`
    /// return `!isSending` fails this test.
    /// HONEST SCOPE: this covers the policy, not the view wiring. Nothing
    /// renders `ChatReplyBar`, so re-adding a bar-wide `.disabled(isSending)`
    /// passes every test here.
    func testReplyBar_whileSending_textFieldStaysEnabled() {
        XCTAssertTrue(ChatReplyBarControlPolicy.isTextFieldEnabled(isSending: true))
        XCTAssertTrue(ChatReplyBarControlPolicy.isTextFieldEnabled(isSending: false))
    }

    /// Revert-check: making `ChatReplyBarControlPolicy.allowsDraftMutation`
    /// return true fails this test.
    /// HONEST SCOPE: policy only, as above.
    func testReplyBar_whileSending_attachmentAndTargetControlsWait() {
        XCTAssertFalse(ChatReplyBarControlPolicy.allowsDraftMutation(isSending: true))
        XCTAssertTrue(ChatReplyBarControlPolicy.allowsDraftMutation(isSending: false))
    }

    /// The optimistic bubble shows its own sending indicator.
    ///
    /// Revert-check: setting `ChatReplyBarControlPolicy.sendButtonShowsProgress`
    /// to true fails this test.
    /// HONEST SCOPE: policy only; ComposeView's `SendButton` keeps the
    /// spinner through the `showsProgress` default.
    func testReplyBar_sendButton_showsNoProgress() {
        XCTAssertFalse(ChatReplyBarControlPolicy.sendButtonShowsProgress)
    }

    /// The quote is sent whenever a target exists, but the row with its
    /// dismiss button used to require a non-empty subject, so a subjectless
    /// message was quoted with no indication and no way to drop it.
    ///
    /// Revert-check: re-adding the non-empty-subject requirement to
    /// `ReplyIndicatorPolicy.header` returns `.none` for both targets.
    /// HONEST SCOPE: this covers the policy, not the view wiring. Nothing
    /// renders `ChatReplyBar`, so re-adding a subject gate in its `body` (the
    /// original bug site) instead of switching on the policy's `.replyingTo`
    /// passes every test here.
    func testReplyIndicator_subjectlessTarget_showsDismissibleRowLabeledBySnippet() {
        XCTAssertEqual(
            ReplyIndicatorPolicy.header(
                isReplyTargetUnavailable: false,
                recoveredRecipients: nil,
                replyTarget: .init(subject: "  ", cleanedSnippet: nil, snippet: "Running 5 min late")
            ),
            .replyingTo(label: "Replying to: Running 5 min late")
        )
        XCTAssertEqual(
            ReplyIndicatorPolicy.header(
                isReplyTargetUnavailable: false,
                recoveredRecipients: nil,
                replyTarget: .init(subject: nil, cleanedSnippet: "", snippet: nil)
            ),
            .replyingTo(label: "Replying to: (no subject)")
        )
    }

    func testReplyIndicator_subjectTarget_keepsSubjectLabel() {
        XCTAssertEqual(
            ReplyIndicatorPolicy.header(
                isReplyTargetUnavailable: false,
                recoveredRecipients: nil,
                replyTarget: .init(subject: "Lunch?", cleanedSnippet: "Noon?", snippet: "Noon?")
            ),
            .replyingTo(label: "Replying to: Lunch?")
        )
    }

    func testReplyIndicator_subjectlessTarget_prefersCleanedSnippetOverRawSnippet() {
        XCTAssertEqual(
            ReplyIndicatorPolicy.replyingToLabel(
                for: .init(subject: nil, cleanedSnippet: "See you there", snippet: "See you there &gt; On Mon")
            ),
            "Replying to: See you there"
        )
    }

    func testReplyIndicator_unavailableTargetAndRecoveredEnvelopeTakePrecedence() {
        let target = ReplyIndicatorPolicy.ReplyTarget(subject: "Lunch?", cleanedSnippet: nil, snippet: nil)
        XCTAssertEqual(
            ReplyIndicatorPolicy.header(
                isReplyTargetUnavailable: true,
                recoveredRecipients: ["a@example.com"],
                replyTarget: target
            ),
            .unavailableTarget
        )
        XCTAssertEqual(
            ReplyIndicatorPolicy.header(
                isReplyTargetUnavailable: false,
                recoveredRecipients: ["a@example.com", "b@example.com"],
                replyTarget: target
            ),
            .recoveredEnvelope(label: "Replying to: a@example.com, b@example.com")
        )
    }

    // MARK: - Recipients the chat's title does not name

    /// A reply that goes to other people than the chat's own says so in the
    /// quote row, before the subject, which is what a narrow row cuts off.
    ///
    /// Revert-check: the `announcedRecipients` argument of
    /// `ReplyIndicatorPolicy.replyingToLabel` (or its use in the label's
    /// prefix). Without it the row reads "Replying to: Dinner" in a chat
    /// titled with someone else's name, and nothing says who gets the reply.
    func testReplyIndicator_announcedRecipientsWithQuote_areNamedInTheQuoteRow() {
        XCTAssertEqual(
            ReplyIndicatorPolicy.header(
                isReplyTargetUnavailable: false,
                recoveredRecipients: nil,
                replyTarget: .init(subject: "Dinner", cleanedSnippet: nil, snippet: nil),
                announcedRecipients: ["sam@example.com", "carol@example.com"]
            ),
            .replyingTo(label: "Replying to sam@example.com, carol@example.com: Dinner")
        )
    }

    /// Dropping the quote keeps the reply's destination, so the recipients
    /// keep a row of their own.
    ///
    /// Revert-check: the `.addressedTo` return for a nil `replyTarget` in
    /// `ReplyIndicatorPolicy.header`. Returning `.none` there leaves a reply
    /// that goes to someone the title does not name with no row at all.
    func testReplyIndicator_announcedRecipientsWithoutQuote_getARowOfTheirOwn() {
        XCTAssertEqual(
            ReplyIndicatorPolicy.header(
                isReplyTargetUnavailable: false,
                recoveredRecipients: nil,
                replyTarget: nil,
                announcedRecipients: ["sam@example.com"]
            ),
            .addressedTo(label: "To: sam@example.com")
        )
    }

    // MARK: - Room for the subject beside announced recipients

    /// A chat with an automated sender whose mail names another address to
    /// answer (GitHub's `reply+<token>@reply.github.com`) announces that
    /// address, and at full length it took the whole one-line row: the
    /// subject, which says which message the reply quotes, was never seen.
    ///
    /// Revert-check: the `abbreviatedAddress` map in
    /// `ReplyIndicatorPolicy.announcedRecipientsText`. Without it the label
    /// carries all 59 characters of the address ahead of the subject. And the
    /// `unabridgedLabel` arguments `ReplyIndicatorPolicy.header` gives the two
    /// cases (pass nil): the address the row cut is then nowhere in the
    /// header, so nothing can show or read it whole.
    func testReplyIndicator_machineReplyToAddress_isShortenedAheadOfTheSubject() {
        let machineAddress = "reply+aaab3xk7q2zp5wj6n4t8yv9rmd0cevfhgs7b@reply.github.com"
        XCTAssertEqual(machineAddress.count, 59)

        XCTAssertEqual(
            ReplyIndicatorPolicy.header(
                isReplyTargetUnavailable: false,
                recoveredRecipients: nil,
                replyTarget: .init(subject: "[repo] Fix the build", cleanedSnippet: nil, snippet: nil),
                announcedRecipients: [machineAddress]
            ),
            .replyingTo(
                label: "Replying to reply+a…s7b@reply.github.com: [repo] Fix the build",
                unabridgedLabel: "Replying to \(machineAddress): [repo] Fix the build"
            )
        )
        // The row of its own too: on the Mac it is one line, and cut at its
        // end the address lost its domain.
        XCTAssertEqual(
            ReplyIndicatorPolicy.header(
                isReplyTargetUnavailable: false,
                recoveredRecipients: nil,
                replyTarget: nil,
                announcedRecipients: [machineAddress]
            ),
            .addressedTo(
                label: "To: reply+a…s7b@reply.github.com",
                unabridgedLabel: "To: \(machineAddress)"
            )
        )
    }

    /// Revert-check: the `limit` argument `ReplyIndicatorPolicy.header` gives
    /// `announcedRecipientsText` for the quote row
    /// (`quoteRowAnnouncedRecipientLimit`). Without it the quote row names all
    /// four ahead of the subject, and the row's end cuts off the later ones
    /// with nothing to say how many there were. And the `unabridgedLabel` of
    /// the `.replyingTo` it returns (pass nil): the two the row only counts
    /// are then named nowhere.
    func testReplyIndicator_manyAnnouncedRecipients_quoteRowCountsTheRest() {
        let recipients = ["a@example.com", "b@example.com", "c@example.com", "d@example.com"]

        XCTAssertEqual(
            ReplyIndicatorPolicy.header(
                isReplyTargetUnavailable: false,
                recoveredRecipients: nil,
                replyTarget: .init(subject: "Dinner", cleanedSnippet: nil, snippet: nil),
                announcedRecipients: recipients
            ),
            .replyingTo(
                label: "Replying to a@example.com, b@example.com +2 more: Dinner",
                unabridgedLabel: "Replying to a@example.com, b@example.com, c@example.com, d@example.com: Dinner"
            )
        )
        // No subject shares the row of its own, so it names everyone, and
        // with nothing cut or counted there is no other label to carry.
        XCTAssertEqual(
            ReplyIndicatorPolicy.header(
                isReplyTargetUnavailable: false,
                recoveredRecipients: nil,
                replyTarget: nil,
                announcedRecipients: recipients
            ),
            .addressedTo(label: "To: a@example.com, b@example.com, c@example.com, d@example.com")
        )
    }

    /// Revert-check: `ReplyIndicatorPolicy.abbreviatedAddress`, case by case.
    /// The guard on `announcedAddressMaxLength` keeps an ordinary address
    /// whole; cutting `domain` to make the address fit would show the start
    /// of a long domain, which can read as somebody else's; and the guard on
    /// `room + 1` (make it `room`) cuts a character from a part one over the
    /// room and draws the address no shorter.
    func testAbbreviatedAddress_cutsOnlyTheLocalPartAndNeverTheDomain() {
        // At the limit: shown whole.
        let atLimit = "firstname.last@example.co.uk"
        XCTAssertEqual(atLimit.count, ReplyIndicatorPolicy.announcedAddressMaxLength)
        XCTAssertEqual(ReplyIndicatorPolicy.abbreviatedAddress(atLimit), atLimit)

        // One over: the local part gives up the room, the domain none.
        XCTAssertEqual(
            ReplyIndicatorPolicy.abbreviatedAddress("firstname.lastn@example.co.uk"),
            "firstname…astn@example.co.uk"
        )

        // A domain longer than the limit is still shown whole, behind the
        // least of the local part that is ever kept.
        XCTAssertEqual(
            ReplyIndicatorPolicy.abbreviatedAddress("notifications@paypal.com.accounts.example.net"),
            "no…s@paypal.com.accounts.example.net"
        )
        // And a local part already that short is left as it is. So is one a
        // single character longer: the mark that stands for the cut takes a
        // place itself, and the address would be drawn no shorter for it.
        for local in ["no", "not", "noti"] {
            let address = "\(local)@paypal.com.accounts.example.net"
            XCTAssertEqual(ReplyIndicatorPolicy.abbreviatedAddress(address), address)
        }

        // No "@" is no address, but it still may not take the row.
        XCTAssertEqual(
            ReplyIndicatorPolicy.abbreviatedAddress(String(repeating: "x", count: 40)),
            String(repeating: "x", count: 27) + "…"
        )
    }

    /// At a mailbox provider the part before the "@" is who gets the mail,
    /// and an address made to pass for another's is most easily made by
    /// adding to its end. Cut to their start alone, two such addresses were
    /// drawn the same, in the one row that says who a reply goes to.
    ///
    /// Revert-check: the `local.suffix(tail)` in
    /// `ReplyIndicatorPolicy.abbreviatedAddress` (set `tail` to 0). Both
    /// addresses are then drawn `alice.johnson.per…@gmail.com`.
    func testAbbreviatedAddress_addressesThatDifferAtTheirEnd_areDrawnDifferently() {
        let finance = ReplyIndicatorPolicy.abbreviatedAddress("alice.johnson.personal.finance@gmail.com")
        let backup = ReplyIndicatorPolicy.abbreviatedAddress("alice.johnson.personal.backup@gmail.com")

        XCTAssertEqual(finance, "alice.johnson…ance@gmail.com")
        XCTAssertEqual(backup, "alice.johnson…ckup@gmail.com")
        XCTAssertEqual(finance.count, ReplyIndicatorPolicy.announcedAddressMaxLength)
    }

    /// Revert-check: the body of `ReplyIndicatorPolicy.wholeLabel` (return
    /// `label`). A row that wraps, VoiceOver and the Mac's tooltip all take
    /// their text from it, and would then repeat the shortened label.
    func testWholeLabel_isTheUnabridgedLabelWhereTheHeaderCarriesOne() {
        XCTAssertEqual(
            ReplyIndicatorPolicy.wholeLabel("To: a…z@example.com", unabridged: "To: a.to.z@example.com"),
            "To: a.to.z@example.com"
        )
        XCTAssertEqual(
            ReplyIndicatorPolicy.wholeLabel("To: sam@example.com", unabridged: nil),
            "To: sam@example.com"
        )
    }

    /// Nothing to announce is the ordinary chat: the rows are as they were.
    func testReplyIndicator_nothingToAnnounce_leavesTheRowsAsTheyWere() {
        for announced in [nil, [String]()] {
            XCTAssertEqual(
                ReplyIndicatorPolicy.header(
                    isReplyTargetUnavailable: false,
                    recoveredRecipients: nil,
                    replyTarget: .init(subject: "Dinner", cleanedSnippet: nil, snippet: nil),
                    announcedRecipients: announced
                ),
                .replyingTo(label: "Replying to: Dinner")
            )
            XCTAssertEqual(
                ReplyIndicatorPolicy.header(
                    isReplyTargetUnavailable: false,
                    recoveredRecipients: nil,
                    replyTarget: nil,
                    announcedRecipients: announced
                ),
                .none
            )
        }
    }

    /// A recovered reply is sent to its stored recipients, and an unavailable
    /// target is not sent at all: what a fresh reply would do is not theirs
    /// to show.
    func testReplyIndicator_announcedRecipients_yieldToRecoveredEnvelopeAndUnavailableTarget() {
        XCTAssertEqual(
            ReplyIndicatorPolicy.header(
                isReplyTargetUnavailable: false,
                recoveredRecipients: ["a@example.com"],
                replyTarget: nil,
                announcedRecipients: ["sam@example.com"]
            ),
            .recoveredEnvelope(label: "Replying to: a@example.com")
        )
        XCTAssertEqual(
            ReplyIndicatorPolicy.header(
                isReplyTargetUnavailable: true,
                recoveredRecipients: nil,
                replyTarget: nil,
                announcedRecipients: ["sam@example.com"]
            ),
            .unavailableTarget
        )
    }

    func testReplyIndicator_noTarget_showsNoRow() {
        XCTAssertEqual(
            ReplyIndicatorPolicy.header(
                isReplyTargetUnavailable: false,
                recoveredRecipients: nil,
                replyTarget: nil
            ),
            .none
        )
    }
}
