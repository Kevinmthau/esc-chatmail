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
    /// And the `unabridgedLabel` argument of the `.replyingTo` that
    /// `ReplyIndicatorPolicy.header` returns (pass it only where it differs
    /// from the label, as it was): this label cuts and counts nothing, so
    /// the header then carries no other, and the iPhone's row does not open
    /// although its one line can end before the second address does.
    func testReplyIndicator_announcedRecipientsWithQuote_areNamedInTheQuoteRow() {
        XCTAssertEqual(
            ReplyIndicatorPolicy.header(
                isReplyTargetUnavailable: false,
                recoveredRecipients: nil,
                replyTarget: .init(subject: "Dinner", cleanedSnippet: nil, snippet: nil),
                announcedRecipients: ["sam@example.com", "carol@example.com"]
            ),
            .replyingTo(
                label: "Replying to sam@example.com, carol@example.com: Dinner",
                unabridgedLabel: "Replying to sam@example.com, carol@example.com: Dinner"
            )
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

    // MARK: - The iPhone's quote row, closed and opened

    /// The cut keeps both ends of an address and still loses its middle, so
    /// two addresses that differ there are drawn the same on the row's one
    /// line. The Mac's row has a tooltip and VoiceOver is read the whole
    /// label; on an iPhone a sighted user had nowhere to see either address
    /// whole. The row opens on a tap, and open it draws the whole label.
    ///
    /// Revert-check: the `isOpen` branch of `ReplyIndicatorPolicy.quoteRow`
    /// (return the closed row whatever `isOpen` says). The opened row then
    /// draws the same short label, and the two replies below still read the
    /// same.
    func testQuoteRow_opened_drawsTheWholeLabel_andTellsApartAddressesTheCutDrawsTheSame() {
        let target = ReplyIndicatorPolicy.ReplyTarget(subject: "Invoice", cleanedSnippet: nil, snippet: nil)
        func row(announcing address: String, isOpen: Bool) -> ReplyIndicatorPolicy.QuoteRow? {
            guard case .replyingTo(let label, let unabridgedLabel) = ReplyIndicatorPolicy.header(
                isReplyTargetUnavailable: false,
                recoveredRecipients: nil,
                replyTarget: target,
                announcedRecipients: [address]
            ) else { return nil }
            return ReplyIndicatorPolicy.quoteRow(label: label, unabridgedLabel: unabridgedLabel, isOpen: isOpen)
        }
        let finance = "alice.johnson.personal.finance@gmail.com"
        let payFinance = "alice.johnson.pay.finance@gmail.com"

        // Closed, the two are one text: the cut dropped the part they differ in.
        XCTAssertEqual(
            row(announcing: finance, isOpen: false),
            .init(text: "Replying to alice.johnson…ance@gmail.com: Invoice", wraps: false, opens: true)
        )
        XCTAssertEqual(row(announcing: payFinance, isOpen: false), row(announcing: finance, isOpen: false))

        XCTAssertEqual(
            row(announcing: finance, isOpen: true),
            .init(text: "Replying to \(finance): Invoice", wraps: true, opens: true)
        )
        XCTAssertEqual(
            row(announcing: payFinance, isOpen: true),
            .init(text: "Replying to \(payFinance): Invoice", wraps: true, opens: true)
        )
    }

    /// The ordinary chat's row announces nobody, carries no other label and
    /// is drawn as it always was: one line, nothing to open, and no mark
    /// that says it opens. Not even where the bar still holds an "open" from
    /// a row that did.
    ///
    /// Revert-check: the `guard let unabridgedLabel` of
    /// `ReplyIndicatorPolicy.quoteRow` (make an open row from `label` where
    /// there is none). Every quote row then opens, and one left open wraps.
    func testQuoteRow_announcingNobody_neverOpens() {
        for isOpen in [false, true] {
            XCTAssertEqual(
                ReplyIndicatorPolicy.quoteRow(label: "Replying to: Lunch?", unabridgedLabel: nil, isOpen: isOpen),
                .init(text: "Replying to: Lunch?", wraps: false, opens: false)
            )
        }
    }

    /// A line that wraps breaks a long word at a syllable and adds a hyphen,
    /// and an address is one long word: `…@accounts.subsidiary.example.com`
    /// was drawn `…@accounts.sub-` and then `sidiary.example.com`, a hyphen
    /// the address does not have. Marked as text in no language it is broken
    /// where the line runs out and nothing is added.
    ///
    /// Revert-check: the `languageIdentifier` assignment in
    /// `ReplyIndicatorPolicy.wrappingLabel` (delete it, or make it for every
    /// word). Deleted, no address is marked; made for every word, the
    /// subject's words are marked too and stop wrapping as words.
    /// HONEST SCOPE: this pins what is marked. That a marked address is drawn
    /// with no hyphen added was looked at in a drawing of the row (test host,
    /// iOS 27.0), and no test asks the text where its lines break.
    func testWrappingLabel_marksEachAddressAsNoLanguage_andNoOtherWord() {
        let label = "Replying to sam@example.com, carol@accounts.subsidiary.example.com: Dinner at eight"

        let marked = ReplyIndicatorPolicy.wrappingLabel(label)

        XCTAssertEqual(String(marked.characters), label, "The row draws the label's own characters")
        var noLanguage: [String] = []
        var otherText = ""
        for run in marked.runs {
            let text = String(marked[run.range].characters)
            if run.languageIdentifier == ReplyIndicatorPolicy.addressLanguageIdentifier {
                noLanguage.append(text)
            } else {
                XCTAssertNil(run.languageIdentifier, text)
                otherText += text
            }
        }
        XCTAssertEqual(noLanguage, ["sam@example.com,", "carol@accounts.subsidiary.example.com:"])
        XCTAssertEqual(otherText, "Replying to   Dinner at eight")
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
