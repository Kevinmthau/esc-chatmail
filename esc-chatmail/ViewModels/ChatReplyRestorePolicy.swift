import Foundation

/// How a reply that never became a durable send is put back into the composer.
///
/// The reply field stays editable while a send is out, so by the time a
/// failure comes back the user may have started the next message. Neither
/// piece of text may be dropped: the composer is the only owner of both.
enum ChatReplyRestorePolicy {
    /// The unsent text, followed by anything typed since the tap.
    static func restoredText(unsentText: String, typedSinceSend: String) -> String {
        guard !typedSinceSend.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return unsentText
        }
        return unsentText + "\n" + typedSinceSend
    }

    /// The unsent attachments first, then any added since the tap, without
    /// duplicates, without rows a rollback or discard already deleted, and
    /// without rows a retained message still owns (those belong to its "Not
    /// sent" bubble, and discarding the draft would leave them alone).
    static func restoredAttachments(
        unsent: [Attachment],
        addedSinceSend: [Attachment]
    ) -> [Attachment] {
        var seen = Set<ObjectIdentifier>()
        return (unsent + addedSinceSend).filter { attachment in
            guard attachment.managedObjectContext != nil,
                  !attachment.isDeleted,
                  attachment.message == nil else { return false }
            return seen.insert(ObjectIdentifier(attachment)).inserted
        }
    }
}
