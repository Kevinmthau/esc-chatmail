import Foundation
import CoreData

extension Message {
    /// Strict participant-set identity derived from persisted MessageParticipant rows.
    ///
    /// Mirrors `makeConversationIdentity`'s participant extraction — From+To+Cc,
    /// BCC excluded, self-aliases removed, same deterministic self-only fallback —
    /// via the shared `makeParticipantSetIdentity` core. Both paths must produce
    /// identical hashes or migrated and freshly-synced messages fork into
    /// duplicate chats.
    ///
    /// Returns nil when the message has no MessageParticipant rows at all. A
    /// row-less message's recipient set is unknowable — `senderEmail` alone
    /// cannot reconstruct To/Cc, and for the user's own sent messages (whose
    /// rows were never written on the optimistic-send reconciliation path) it
    /// would collapse them into the note-to-self chat. Such messages must not
    /// be re-homed.
    func strictParticipantSetIdentity(myAliases: Set<String>) -> ParticipantSetIdentity? {
        var emails = Set<String>()
        var hasFromRow = false
        var hasIdentityRow = false

        for participant in participants ?? [] {
            let kind = participant.participantKind
            // BCC is excluded from identity, matching makeConversationIdentity
            guard kind != .bcc else { continue }
            hasIdentityRow = true
            if kind == .from {
                hasFromRow = true
            }
            // The header path drops Hide-My-Email entries from From, To, and
            // Cc; mirror that exclusion for every identity row (best effort —
            // the stored display name can have been enriched since) so both
            // derivations key HME mail the same way.
            if let name = participant.person?.displayName,
               EmailNormalizer.isHideMyEmailDisplayName(name) {
                continue
            }
            guard let person = participant.person else { continue }
            // Person.email is normalized at write time; re-normalizing is idempotent
            let normalized = normalizedEmail(person.email)
            if !normalized.isEmpty { emails.insert(normalized) }
        }

        guard hasIdentityRow else { return nil }

        // senderEmail is stored un-normalized and only supplements a legacy row
        // set that lacks a .from participant
        if !hasFromRow, let sender = senderEmail {
            let normalized = normalizedEmail(sender)
            if !normalized.isEmpty { emails.insert(normalized) }
        }

        guard !emails.isEmpty else { return nil }

        // Mailing-list mail keys by its persisted List-Id, mirroring the
        // header path's list branch. Messages persisted before the listId
        // attribute existed have nil here and stay participant-keyed unless a
        // later full refetch supplies List-Id and reroutes that individual row.
        // There is intentionally no all-mail historical backfill.
        if let listId, !listId.isEmpty {
            return makeListSetIdentity(normalizedListId: listId,
                                       normalizedEmails: emails,
                                       myAliases: myAliases)
        }

        return makeParticipantSetIdentity(normalizedEmails: emails, myAliases: myAliases)
    }
}
