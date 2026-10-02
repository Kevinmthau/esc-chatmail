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

    /// The text of a stored draft after an unsent reply is merged into it
    /// (no composer is on screen to take it).
    ///
    /// Merges must be idempotent: a rollback already merges the reply's body
    /// into the stored draft, unsent text first, before the off-screen view
    /// model hands the same snapshot over. Stored text that already starts
    /// with the unsent text is kept as is, or the reply would appear twice.
    static func mergedStoredText(unsentText: String, storedText: String) -> String {
        let unsent = unsentText.trimmingCharacters(in: .whitespacesAndNewlines)
        let stored = storedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !unsent.isEmpty, !stored.hasPrefix(unsent) else { return storedText }
        return restoredText(unsentText: unsentText, typedSinceSend: storedText)
    }

    /// The draft an unsent reply becomes when merged into the stored draft.
    ///
    /// Only one destination survives a merge. The stored draft's wins when it
    /// has one: it belongs to text written after this reply (or to an earlier
    /// merge of this same reply), and the composer shows it as the header, so
    /// the user sees where the merged text will go before sending.
    @MainActor
    static func mergedDraft(
        unsent: StoredChatReplyDraft,
        stored: StoredChatReplyDraft?,
        storedHasAttachments: Bool
    ) -> StoredChatReplyDraft {
        guard let stored,
              ChatComposerState.hasDraftContent(
                  replyText: stored.text,
                  hasAttachments: storedHasAttachments
              ) else {
            return unsent
        }
        let text = mergedStoredText(unsentText: unsent.text, storedText: stored.text)
        guard stored.targetURI != nil || stored.recoveredEnvelope != nil else {
            return StoredChatReplyDraft(
                text: text,
                targetURI: unsent.targetURI,
                recoveredEnvelope: unsent.recoveredEnvelope,
                includesQuotedMessage: unsent.includesQuotedMessage
            )
        }
        return StoredChatReplyDraft(
            text: text,
            targetURI: stored.targetURI,
            recoveredEnvelope: stored.recoveredEnvelope,
            includesQuotedMessage: stored.includesQuotedMessage
        )
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
