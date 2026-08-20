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
    let showsGroupAvatar: Bool
    let conversationType: ConversationType

    init(from conversation: Conversation) {
        let conversationType = conversation.conversationType
        self.objectID = conversation.objectID
        self.inboxUnreadCount = conversation.inboxUnreadCount
        self.pinned = conversation.pinned
        self.snippet = conversation.snippet
        self.lastMessageDate = conversation.lastMessageDate
        self.displayNameHint = conversation.displayName
        self.participantHash = conversation.participantHash
        self.participantEmails = conversationType == .list
            ? []
            : Self.participantEmails(from: conversation)
        self.participantDisplayNameFingerprint = conversationType == .list
            ? ""
            : Self.participantDisplayNameFingerprint(from: conversation)
        self.showsGroupAvatar = conversationType != .oneToOne
        self.conversationType = conversationType
    }

    private static func participantEmails(from conversation: Conversation) -> [String] {
        let emails = conversation.participants?
            .compactMap { participant -> String? in
                guard let person = participant.person else { return nil }
                guard !EmailNormalizer.isHideMyEmailDisplayName(person.displayName) else { return nil }
                let normalizedEmail = EmailNormalizer.normalize(person.email)
                return normalizedEmail.isEmpty ? nil : normalizedEmail
            } ?? []

        return Array(Set(emails)).sorted()
    }

    private static func participantDisplayNameFingerprint(from conversation: Conversation) -> String {
        let entries = conversation.participants?
            .compactMap { participant -> String? in
                guard let person = participant.person else { return nil }
                let normalizedEmail = EmailNormalizer.normalize(person.email)
                guard !normalizedEmail.isEmpty else { return nil }
                return "\(normalizedEmail)=\(person.displayName ?? "")"
            } ?? []

        return Array(Set(entries)).sorted().joined(separator: "|")
    }
}
