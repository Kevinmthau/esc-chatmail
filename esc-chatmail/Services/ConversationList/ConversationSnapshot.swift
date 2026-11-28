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
    /// The participants' (normalized address, display name) pairs that
    /// `participantDisplayNameFingerprint` is built from, sorted. Kept as
    /// values because the joined fingerprint cannot be split back into them
    /// (an address or a name may contain `=` or `|`), and the list asks of
    /// them whether a changed Person's name is already the one its rows show
    /// (`ConversationListPersonChangePolicy`). Empty for a list conversation,
    /// whose row shows no participant.
    let participantDisplayNames: [ParticipantDisplayName]
    let conversationType: ConversationType

    /// One participant as the row's fingerprint records it: the person's
    /// normalized address and its display name, `""` for none.
    struct ParticipantDisplayName: Hashable, Comparable {
        let email: String
        let displayName: String

        static func < (lhs: ParticipantDisplayName, rhs: ParticipantDisplayName) -> Bool {
            (lhs.email, lhs.displayName) < (rhs.email, rhs.displayName)
        }
    }

    /// Derived, not stored: always `conversationType != .oneToOne`, so the
    /// synthesized `Equatable` correctly ignores it (`conversationType` itself
    /// is compared).
    var showsGroupAvatar: Bool {
        Self.showsGroupAvatar(conversationType: conversationType)
    }

    /// The rule behind `showsGroupAvatar`, for a caller that has a conversation's type and no
    /// snapshot: the chat header draws the row's avatar (`ChatHeaderPolicy.avatar`).
    static func showsGroupAvatar(conversationType: ConversationType) -> Bool {
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
            ? (emails: [], fingerprint: "", displayNames: [])
            : Self.participantFields(from: conversation)
        self.participantEmails = participantFields.emails
        self.participantDisplayNameFingerprint = participantFields.fingerprint
        self.participantDisplayNames = participantFields.displayNames
        self.conversationType = conversationType
    }

    /// One walk over `conversation.participants` building both
    /// participant-derived fields. The hide-my-email asymmetry is DELIBERATE —
    /// do not "clean up" by merging the two rules: `emails` EXCLUDES persons
    /// whose display name is a Hide My Email relay label (they are routing
    /// aliases, not real participants, so they must not feed the fallback
    /// display name), while `fingerprint` INCLUDES them (their display data
    /// still renders in participant rollups, so a change to it must still be
    /// detected as a fingerprint change). `displayNames` holds the same pairs
    /// as `fingerprint`, as values.
    private static func participantFields(
        from conversation: Conversation
    ) -> (emails: [String], fingerprint: String, displayNames: [ParticipantDisplayName]) {
        var emails = Set<String>()
        var fingerprintEntries = Set<String>()
        var displayNames = Set<ParticipantDisplayName>()

        for participant in conversation.participants ?? [] {
            guard let person = participant.person else { continue }
            let normalizedEmail = EmailNormalizer.normalize(person.email)
            guard !normalizedEmail.isEmpty else { continue }

            let displayName = person.displayName ?? ""
            fingerprintEntries.insert("\(normalizedEmail)=\(displayName)")
            displayNames.insert(ParticipantDisplayName(email: normalizedEmail, displayName: displayName))

            if !EmailNormalizer.isHideMyEmailDisplayName(person.displayName) {
                emails.insert(normalizedEmail)
            }
        }

        return (
            emails: emails.sorted(),
            fingerprint: fingerprintEntries.sorted().joined(separator: "|"),
            displayNames: displayNames.sorted()
        )
    }
}
