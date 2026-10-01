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

    /// A pending send is still being transmitted, and a `.none` row was accepted (or is a
    /// `.sendFailed` attachment upload with no recovery path): no dialog, so the bubble keeps its
    /// normal tap.
    func testPrompt_sendingOrNone_offersNothing() {
        XCTAssertNil(FailedSendRecoveryPolicy.prompt(for: .sending))
        XCTAssertNil(FailedSendRecoveryPolicy.prompt(for: .none))
    }
}
