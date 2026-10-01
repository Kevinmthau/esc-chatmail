import Foundation

/// What a failed outgoing bubble offers when the user taps it or the exclamation badge beside it.
///
/// Every action routes to a recovery path that already existed behind the long-press menu
/// (`ChatViewModel.editFailedReply` / `checkReplyDelivery`); this adds no send path of its own.
/// Gmail `messages.send` has no idempotency key, so the actions are keyed on the durable
/// `OutboundSendDeliveryState` and never on anything weaker:
/// - `.notSent` is a definite pre-transmission failure: Gmail never saw the reply. "Edit and
///   Resend" moves it back into the composer, and the user explicitly sends a new message.
/// - `.deliveryUnknown` is ambiguous post-barrier: Gmail may already have it. Offering a resend
///   there is a duplicate-send hazard, so it offers only "Check Delivery", which re-reads Gmail.
/// - `.sendFailed` (a local attachment upload failed; delivery state `.none`) has no recovery path
///   to route to, so it gets no dialog.
enum FailedSendRecoveryPolicy {
    enum Action: Hashable {
        /// `ChatViewModel.editFailedReply`: the reply back in the composer for a new, explicit send.
        case editAndResend
        /// `ChatViewModel.checkReplyDelivery`: re-checks Gmail. Never retransmits.
        case checkDelivery

        var title: String {
            switch self {
            case .editAndResend:
                return "Edit and Resend"
            case .checkDelivery:
                return "Check Delivery"
            }
        }
    }

    struct Prompt: Equatable {
        let title: String
        let message: String
        let actions: [Action]
    }

    static let accessibilityHint = "Shows options for this unsent reply"

    /// The dialog for a row in `deliveryState`; nil when the row has nothing to recover.
    static func prompt(for deliveryState: OutboundSendDeliveryState) -> Prompt? {
        switch deliveryState {
        case .notSent:
            return Prompt(
                title: "Not Sent",
                message: "This reply was not sent.",
                actions: [.editAndResend]
            )
        case .deliveryUnknown:
            return Prompt(
                title: "Delivery Unknown",
                message: "This reply won’t be retried automatically.",
                actions: [.checkDelivery]
            )
        case .none, .sending:
            return nil
        }
    }
}
