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
