import Foundation
import CoreData

extension Account {
    @nonobjc public class func fetchRequest() -> NSFetchRequest<Account> {
        return NSFetchRequest<Account>(entityName: "Account")
    }
    
    @NSManaged public var id: String
    @NSManaged public var email: String
    @NSManaged public var historyId: String?
    @NSManaged public var aliases: String? // Comma-separated list of email aliases
    
    var aliasesArray: [String] {
        get {
            guard let aliases = aliases else { return [] }
            return aliases.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
        }
        set {
            aliases = newValue.joined(separator: ",")
        }
    }
}

extension Person {
    @nonobjc public class func fetchRequest() -> NSFetchRequest<Person> {
        return NSFetchRequest<Person>(entityName: "Person")
    }
    
    @NSManaged public var id: UUID
    @NSManaged public var email: String
    @NSManaged public var displayName: String?
    @NSManaged public var avatarURL: String?
    @NSManaged public var conversationParticipations: Set<ConversationParticipant>?
    @NSManaged public var messageParticipations: Set<MessageParticipant>?
}

extension Conversation {
    @nonobjc public class func fetchRequest() -> NSFetchRequest<Conversation> {
        return NSFetchRequest<Conversation>(entityName: "Conversation")
    }
    
    @NSManaged public var id: UUID
    @NSManaged public var type: String
    @NSManaged public var keyHash: String
    @NSManaged public var displayName: String?
    @NSManaged public var lastMessageDate: Date?
    @NSManaged public var snippet: String?
    @NSManaged public var pinned: Bool
    @NSManaged public var muted: Bool
    @NSManaged public var hasInbox: Bool
    @NSManaged public var inboxUnreadCount: Int32
    @NSManaged public var latestInboxDate: Date?
    @NSManaged public var hidden: Bool
    @NSManaged public var messages: Set<Message>?
    @NSManaged public var participants: Set<ConversationParticipant>?
    
    var conversationType: ConversationType {
        get { ConversationType(rawValue: type) ?? .oneToOne }
        set { type = newValue.rawValue }
    }
}

extension ConversationParticipant {
    @nonobjc public class func fetchRequest() -> NSFetchRequest<ConversationParticipant> {
        return NSFetchRequest<ConversationParticipant>(entityName: "ConversationParticipant")
    }
    
    @NSManaged public var id: UUID
    @NSManaged public var role: String
    @NSManaged public var person: Person?
    @NSManaged public var conversation: Conversation?
    
    var participantRole: ParticipantRole {
        get { ParticipantRole(rawValue: role) ?? .normal }
        set { role = newValue.rawValue }
    }
}

extension Message {
    @nonobjc public class func fetchRequest() -> NSFetchRequest<Message> {
        return NSFetchRequest<Message>(entityName: "Message")
    }
    
    @NSManaged public var id: String
    @NSManaged public var gmThreadId: String
    @NSManaged public var internalDate: Date
    @NSManaged public var subject: String?
    @NSManaged public var snippet: String?
    @NSManaged public var isFromMe: Bool
    @NSManaged public var isUnread: Bool
    @NSManaged public var hasAttachments: Bool
    @NSManaged public var bodyStorageURI: String?
    @NSManaged public var conversation: Conversation?
    @NSManaged public var labels: Set<Label>?
    @NSManaged public var participants: Set<MessageParticipant>?
}

extension MessageParticipant {
    @nonobjc public class func fetchRequest() -> NSFetchRequest<MessageParticipant> {
        return NSFetchRequest<MessageParticipant>(entityName: "MessageParticipant")
    }
    
    @NSManaged public var id: UUID
    @NSManaged public var kind: String
    @NSManaged public var message: Message?
    @NSManaged public var person: Person?
    
    var participantKind: ParticipantKind {
        get { ParticipantKind(rawValue: kind) ?? .from }
        set { kind = newValue.rawValue }
    }
}

extension Label {
    @nonobjc public class func fetchRequest() -> NSFetchRequest<Label> {
        return NSFetchRequest<Label>(entityName: "Label")
    }
    
    @NSManaged public var id: String
    @NSManaged public var name: String
    @NSManaged public var messages: Set<Message>?
}

enum ConversationType: String {
    case oneToOne = "oneToOne"
    case group = "group"
    case list = "list"
}

enum ParticipantRole: String {
    case normal = "normal"
    case me = "me"
    case listAddress = "listAddress"
}

enum ParticipantKind: String {
    case from = "from"
    case to = "to"
    case cc = "cc"
    case bcc = "bcc"
}