import Foundation
import CoreData

/// Snapshot of conversation data to prevent excessive re-renders.
/// Instead of observing the full Conversation object (which triggers re-renders on ANY property change),
/// we capture only the display-relevant properties once and update via explicit refresh.
struct ConversationSnapshot: Equatable {
    let objectID: NSManagedObjectID
    let inboxUnreadCount: Int32
    let pinned: Bool
    let snippet: String?
    let lastMessageDate: Date?
    let displayNameHint: String?
    let participantHash: String?
    let participantEmails: [String]
    let participantDisplayNameFingerprint: String
    let conversationType: ConversationType

    /// Derived, not stored: always `conversationType != .oneToOne`, so the
    /// synthesized `Equatable` correctly ignores it (`conversationType` itself
    /// is compared).
    var showsGroupAvatar: Bool {
        conversationType != .oneToOne
    }

    init(from conversation: Conversation) {
        let conversationType = conversation.conversationType
        self.objectID = conversation.objectID
        self.inboxUnreadCount = conversation.inboxUnreadCount
        self.pinned = conversation.pinned
        self.snippet = conversation.snippet
        self.lastMessageDate = conversation.lastMessageDate
        self.displayNameHint = conversation.displayName
        self.participantHash = conversation.participantHash
        let participantFields = conversationType == .list
            ? (emails: [], fingerprint: "")
            : Self.participantFields(from: conversation)
        self.participantEmails = participantFields.emails
        self.participantDisplayNameFingerprint = participantFields.fingerprint
        self.conversationType = conversationType
    }

    /// One walk over `conversation.participants` building both
    /// participant-derived fields. The hide-my-email asymmetry is DELIBERATE —
    /// do not "clean up" by merging the two rules: `emails` EXCLUDES persons
    /// whose display name is a Hide My Email relay label (they are routing
    /// aliases, not real participants, so they must not feed the fallback
    /// display name), while `fingerprint` INCLUDES them (their display data
    /// still renders in participant rollups, so a change to it must still be
    /// detected as a fingerprint change).
    private static func participantFields(
        from conversation: Conversation
    ) -> (emails: [String], fingerprint: String) {
        var emails = Set<String>()
        var fingerprintEntries = Set<String>()

        for participant in conversation.participants ?? [] {
            guard let person = participant.person else { continue }
            let normalizedEmail = EmailNormalizer.normalize(person.email)
            guard !normalizedEmail.isEmpty else { continue }

            fingerprintEntries.insert("\(normalizedEmail)=\(person.displayName ?? "")")

            if !EmailNormalizer.isHideMyEmailDisplayName(person.displayName) {
                emails.insert(normalizedEmail)
            }
        }

        return (
            emails: emails.sorted(),
            fingerprint: fingerprintEntries.sorted().joined(separator: "|")
        )
    }
}
