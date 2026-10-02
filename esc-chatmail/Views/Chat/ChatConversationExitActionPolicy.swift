import Foundation

/// When the chat's overflow-menu Archive and Report Spam run relative to a
/// reply send.
///
/// Both act on the conversation a reply's optimistic message anchors to, so
/// they never run while a send holds the composer (`ChatComposerState
/// .isSending`: from the tap until that message is durable; milliseconds,
/// longer when optimistic creation waits on the cleanup gate). The menu
/// stays enabled through that window, on purpose: gating it with the back
/// button made the navigation bar blink on every reply (`ChatView
/// .allowsNavigationExit`). Until this policy the action-time guard then
/// dropped the tap without a word, so the user's first Archive did nothing.
///
/// Instead the tap is remembered and settled when the send releases the
/// composer (`ChatViewModel.sendReply`), re-validated against the state at
/// that moment:
/// - The reply became durable: run it. From here on the optimistic graph owns
///   the reply, exactly as for a tap made a moment later, and a later
///   rollback never undoes an archive made meanwhile. The screen it was
///   tapped on is dismissed only if it is still the one on screen.
/// - The reply came back (a failure before persistence): drop it. The reply
///   is back in the composer with an alert, or merged into the stored draft
///   when the screen is gone. Archiving then would hide both: the dismissal
///   takes the alert with it, and the unsent reply sits as a draft in an
///   archived (or spam) conversation the user is unlikely to find. The chat
///   stays, so the user can choose again.
/// - The chat was opened again since the tap: drop it. The user came back to
///   the conversation, and archiving it under the reopened screen would
///   contradict that newer choice.
/// - The account changed or the conversation is gone or drained: drop it;
///   there is nothing left to act on.
enum ChatConversationExitActionPolicy {
    enum Action: String, Equatable {
        case archive
        case reportSpam
    }

    /// What a tap on Archive or Report Spam does now.
    enum TapDecision: Equatable {
        /// No reply holds the composer: act and leave the chat.
        case performNow
        /// A reply holds the composer; settle the tap when it releases it
        /// (`releaseDecision`). A later tap replaces an earlier one: the
        /// user's latest choice is their intent.
        case deferUntilSendReleases
    }

    /// How the send that held the composer released it.
    enum SendRelease: Equatable {
        /// The optimistic message is durable (`onOptimisticMessagePersisted`).
        case replyPersisted
        /// The send failed or was rolled back before that, and the reply was
        /// handed back to a composer or to the stored draft.
        case replyReturned
    }

    /// Where the screen the tap was made on is when the send releases.
    enum Presentation: Equatable {
        /// Still on screen (`ChatReplyComposerDirectory.presentedComposer`).
        case onScreen
        /// Gone, and no other screen for the conversation is open.
        case left
        /// Gone, and the conversation was opened again in a new screen.
        case reopened
    }

    enum DropReason: String, Equatable {
        case replyReturned
        case chatReopened
        case accountChanged
        case conversationUnavailable
    }

    /// What a deferred tap does once its send released the composer.
    enum ReleaseDecision: Equatable {
        case performAndDismiss
        /// The user already left the chat; there is no screen to dismiss.
        case performWithoutDismissing
        case drop(DropReason)
    }

    static func tapDecision(isSending: Bool) -> TapDecision {
        isSending ? .deferUntilSendReleases : .performNow
    }

    static func releaseDecision(
        release: SendRelease,
        accountIsUnchanged: Bool,
        conversationIsAvailable: Bool,
        presentation: Presentation
    ) -> ReleaseDecision {
        guard accountIsUnchanged else { return .drop(.accountChanged) }
        guard conversationIsAvailable else { return .drop(.conversationUnavailable) }
        guard release == .replyPersisted else { return .drop(.replyReturned) }
        switch presentation {
        case .onScreen:
            return .performAndDismiss
        case .left:
            return .performWithoutDismissing
        case .reopened:
            return .drop(.chatReopened)
        }
    }
}
