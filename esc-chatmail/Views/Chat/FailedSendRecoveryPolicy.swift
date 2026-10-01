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
        /// VoiceOver hint for the bubble and badge that open this dialog. Per prompt, because
        /// calling an ambiguous send "unsent" invites the manual duplicate the orange badge and
        /// the "won’t be retried" copy are there to avoid.
        let accessibilityHint: String
    }

    /// The dialog for a row in `deliveryState`; nil when the row has nothing to recover.
    static func prompt(for deliveryState: OutboundSendDeliveryState) -> Prompt? {
        switch deliveryState {
        case .notSent:
            return Prompt(
                title: "Not Sent",
                message: "This reply was not sent.",
                actions: [.editAndResend],
                accessibilityHint: "Shows options for this unsent reply"
            )
        case .deliveryUnknown:
            return Prompt(
                title: "Delivery Unknown",
                message: "This reply won’t be retried automatically.",
                actions: [.checkDelivery],
                accessibilityHint: "Shows options to check whether this reply was delivered"
            )
        case .none, .sending:
            return nil
        }
    }

    /// The dialog's chosen action to run now, or nil while the dialog is still presented.
    ///
    /// A dialog button only records its action; the bubble runs it once the dialog is gone.
    /// Edit and Resend moves focus into the composer and can raise an alert ("Draft Already
    /// Open", "Couldn’t Recover Reply"). Made in the same update that dismisses a confirmation
    /// dialog, either can be dropped: the reply lands in the composer with no keyboard, or, with
    /// a draft already open, nothing visibly happens. The long-press menu runs its actions
    /// directly, as it always has.
    static func actionToRun(pending: Action?, isDialogPresented: Bool) -> Action? {
        isDialogPresented ? nil : pending
    }
}
