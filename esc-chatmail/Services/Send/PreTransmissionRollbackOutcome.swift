import Foundation

/// What `rollbackOptimisticMessageBeforeTransmission` actually did.
///
/// A rollback hands a reply's content back through a `ChatReplyDraft` in the
/// same save that deletes the optimistic graph. When that draft cannot be
/// written (an undecodable stored envelope, a failed draft fetch) the rollback
/// keeps the row as "Not sent" instead, so the content still has exactly one
/// durable owner. The caller must then treat the send as retained, not
/// rolled back: failing admission would make the chat composer restore the
/// same text and attachments the retained bubble still shows, and the user
/// could send them twice (once from the composer, once via Edit and resend).
enum PreTransmissionRollbackOutcome: Equatable, Sendable {
    /// The optimistic graph is gone; the source composer (or the restored
    /// `ChatReplyDraft`) owns the content again.
    case rolledBack
    /// The optimistic graph was kept as definitely unsent; its bubble owns
    /// the content.
    case retainedAsNotSent
}
