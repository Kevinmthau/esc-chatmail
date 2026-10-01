import Foundation
import CoreData

/// The composer content a reply send took at tap.
///
/// `ChatViewModel.sendReply` clears the composer in the tap's main-actor turn,
/// so until `createOptimisticMessage` makes the optimistic graph durable this
/// value is the only owner of the text and attachments. A failure before then
/// (or a later rollback) restores it through `ChatReplyRestorePolicy`.
@MainActor
struct ChatReplySendSnapshot {
    /// The reply destination as the composer held it. Compared by identity to
    /// tell whether the user picked another target while the send was out.
    struct Target {
        let replyingTo: Message?
        let replyAnchor: Message?
        let recoveredReplyEnvelope: StoredReplyEnvelope?
        let manuallySelectedReplyTargetID: NSManagedObjectID?

        /// Envelopes compare by value: Edit and resend replaces one recovered
        /// envelope with another, and a nil-ness comparison read that swap as
        /// "unchanged", so a rollback overwrote the newly recovered
        /// destination.
        func hasSameIdentity(as other: Target) -> Bool {
            replyingTo?.objectID == other.replyingTo?.objectID &&
                replyAnchor?.objectID == other.replyAnchor?.objectID &&
                recoveredReplyEnvelope == other.recoveredReplyEnvelope &&
                manuallySelectedReplyTargetID == other.manuallySelectedReplyTargetID
        }

        /// A deleted target cannot be restored; the composer keeps whatever
        /// it holds now and send validation reports the gap.
        var isRestorable: Bool {
            [replyingTo, replyAnchor].allSatisfy { message in
                message.map { $0.managedObjectContext != nil && !$0.isDeleted } ?? true
            }
        }
    }

    /// The raw field text, not the trimmed body that was sent, so an exact
    /// restore puts back exactly what the user saw.
    let replyText: String
    let attachments: [Attachment]
    let target: Target

    /// The snapshot as a durable draft, the way
    /// `ChatViewModel.saveReplyDraft` would have stored this composer.
    var storedDraft: StoredChatReplyDraft {
        StoredChatReplyDraft(
            text: replyText,
            targetURI: target.replyAnchor?.objectID.uriRepresentation(),
            recoveredEnvelope: target.recoveredReplyEnvelope,
            includesQuotedMessage: target.replyingTo != nil
        )
    }
}
