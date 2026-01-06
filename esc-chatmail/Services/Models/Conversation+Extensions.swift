import Foundation
import CoreData

extension Conversation {
    @nonobjc public class func fetchRequest() -> NSFetchRequest<Conversation> {
        return NSFetchRequest<Conversation>(entityName: "Conversation")
    }

    @NSManaged public var id: UUID
    @NSManaged public var type: String
    @NSManaged public var keyHash: String
    @NSManaged public var participantHash: String?
    @NSManaged public var displayName: String?
    @NSManaged public var lastMessageDate: Date?
    @NSManaged public var snippet: String?
    @NSManaged public var pinned: Bool
    @NSManaged public var muted: Bool
    @NSManaged public var hasInbox: Bool
    @NSManaged public var inboxUnreadCount: Int32
    @NSManaged public var latestInboxDate: Date?
    @NSManaged public var hidden: Bool
    @NSManaged public var archivedAt: Date?
    @NSManaged public var messages: Set<Message>?
    @NSManaged public var participants: Set<ConversationParticipant>?

    var conversationType: ConversationType {
        get { ConversationType(rawValue: type) ?? .oneToOne }
        set { type = newValue.rawValue }
    }

    var participantsArray: [String] {
        guard let participants = participants else { return [] }
        return participants.compactMap { $0.person?.email }
    }

    var lastMessageTime: Date? {
        get { lastMessageDate }
        set { lastMessageDate = newValue }
    }

    var lastMessagePreview: String? {
        get { snippet }
        set { snippet = newValue }
    }

    /// Returns true if this conversation is archived (has been dismissed by the user)
    var isArchived: Bool {
        return archivedAt != nil
    }
}
