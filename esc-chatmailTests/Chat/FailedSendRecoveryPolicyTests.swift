import XCTest
@testable import esc_chatmail

final class FailedSendRecoveryPolicyTests: XCTestCase {
    /// A definite pre-transmission failure: Gmail never saw the reply, so the explicit
    /// edit-and-resend flow (content back to the composer, then a new user-initiated send) is safe.
    ///
    /// Revert-check: returning nil for `.notSent` in `FailedSendRecoveryPolicy.prompt` (no dialog,
    /// so the bubble tap falls back to opening the reader) fails this test.
    func testPrompt_notSent_offersEditAndResendOnly() throws {
        let prompt = try XCTUnwrap(FailedSendRecoveryPolicy.prompt(for: .notSent))

        XCTAssertEqual(prompt.actions, [.editAndResend])
        XCTAssertEqual(prompt.title, "Not Sent")
        XCTAssertEqual(FailedSendRecoveryPolicy.Action.editAndResend.title, "Edit and Resend")
    }

    /// Gmail `messages.send` has no idempotency key, and an ambiguous post-barrier send may already
    /// be in Gmail. Any resend affordance here is a duplicate-send hazard.
    ///
    /// Revert-check: adding `.editAndResend` to the `.deliveryUnknown` prompt in
    /// `FailedSendRecoveryPolicy.prompt` fails this test.
    func testPrompt_deliveryUnknown_offersCheckDeliveryAndNeverResend() throws {
        let prompt = try XCTUnwrap(FailedSendRecoveryPolicy.prompt(for: .deliveryUnknown))

        XCTAssertEqual(prompt.actions, [.checkDelivery])
        XCTAssertFalse(prompt.actions.contains(.editAndResend))
        XCTAssertEqual(FailedSendRecoveryPolicy.Action.checkDelivery.title, "Check Delivery")
        XCTAssertEqual(prompt.message, "This reply won’t be retried automatically.")
    }

    /// VoiceOver must not call an ambiguous send "unsent": Gmail may already have it, and that
    /// framing invites a manual duplicate of a non-idempotent send.
    ///
    /// Revert-check: giving the `.deliveryUnknown` prompt the "unsent reply" hint in
    /// `FailedSendRecoveryPolicy.prompt` (the single shared hint this replaced) fails this test.
    func testPrompt_accessibilityHint_onlyNotSentCallsTheReplyUnsent() throws {
        let notSent = try XCTUnwrap(FailedSendRecoveryPolicy.prompt(for: .notSent))
        let deliveryUnknown = try XCTUnwrap(FailedSendRecoveryPolicy.prompt(for: .deliveryUnknown))

        XCTAssertEqual(notSent.accessibilityHint, "Shows options for this unsent reply")
        XCTAssertEqual(
            deliveryUnknown.accessibilityHint,
            "Shows options to check whether this reply was delivered"
        )
        XCTAssertFalse(deliveryUnknown.accessibilityHint.localizedCaseInsensitiveContains("unsent"))
    }

    /// A pending send is still being transmitted, and a `.none` row has nothing to recover (an
    /// accepted reply, or a `.sendFailed` attachment upload with no recovery path): no dialog, so
    /// the bubble keeps its normal tap.
    func testPrompt_sendingOrNone_offersNothing() {
        XCTAssertNil(FailedSendRecoveryPolicy.prompt(for: .sending))
        XCTAssertNil(FailedSendRecoveryPolicy.prompt(for: .none))
    }

    /// The dialog's action waits for the dialog to go away, so Edit and Resend's composer focus
    /// and its "Draft Already Open" alert are not made while the dialog is still dismissing.
    ///
    /// Revert-check: returning `pending` regardless of `isDialogPresented` in
    /// `FailedSendRecoveryPolicy.actionToRun` fails the presented assertions.
    ///
    /// HONEST SCOPE: pins the decision only. That `MessageBubble` consults it from both the dialog
    /// button and the presentation change, and that focus and the alert then survive on a device,
    /// is view wiring with no UI test target.
    func testActionToRun_dialogStillPresented_waitsUntilDismissed() {
        typealias Policy = FailedSendRecoveryPolicy
        XCTAssertNil(Policy.actionToRun(pending: .editAndResend, isDialogPresented: true))
        XCTAssertNil(Policy.actionToRun(pending: .checkDelivery, isDialogPresented: true))

        XCTAssertEqual(Policy.actionToRun(pending: .editAndResend, isDialogPresented: false), .editAndResend)
        XCTAssertEqual(Policy.actionToRun(pending: .checkDelivery, isDialogPresented: false), .checkDelivery)
        // Cancel records nothing, so dismissal runs nothing.
        XCTAssertNil(Policy.actionToRun(pending: nil, isDialogPresented: false))
    }
}
