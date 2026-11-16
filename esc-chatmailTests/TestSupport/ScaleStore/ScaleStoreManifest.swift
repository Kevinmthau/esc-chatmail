import Foundation

/// What a seeded store holds, for a test to aim at and to check against.
struct ScaleStoreManifest: Equatable, Sendable {
    let shape: ScaleStoreShape
    let selfEmail: String
    /// The mailing-list conversation with `largestConversationMessageCount` messages.
    let largestConversationID: UUID
    let largestConversationMessageCount: Int
    /// A conversation of ordinary size, in the inbox, with unread mail.
    let ordinaryConversationID: UUID
    let ordinaryConversationMessageCount: Int
    let ordinaryConversationUnreadCount: Int
    /// A received message of the ordinary conversation that carries INBOX.
    let ordinaryConversationInboxMessageID: String
    let messageCount: Int
    let inboxMessageCount: Int
    let unreadMessageCount: Int
    let messageParticipantCount: Int
    let labelMembershipCount: Int
    let archivedConversationCount: Int
}
