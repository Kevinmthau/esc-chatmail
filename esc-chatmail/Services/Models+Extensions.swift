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
    
    var name: String? {
        return displayName
    }
}

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
    @NSManaged public var cleanedSnippet: String?
    @NSManaged public var isFromMe: Bool
    @NSManaged public var isUnread: Bool
    @NSManaged public var isNewsletter: Bool
    @NSManaged public var hasAttachments: Bool
    @NSManaged public var bodyStorageURI: String?
    @NSManaged public var bodyText: String?
    @NSManaged public var senderName: String?
    @NSManaged public var senderEmail: String?
    @NSManaged public var messageId: String?
    @NSManaged public var references: String?
    @NSManaged public var localModifiedAt: Date?
    @NSManaged public var conversation: Conversation?
    @NSManaged public var labels: Set<Label>?
    @NSManaged public var participants: Set<MessageParticipant>?
    @NSManaged public var attachments: Set<Attachment>?

    var content: String? {
        get { cleanedSnippet }
        set { cleanedSnippet = newValue }
    }

    var timestamp: Date {
        get { internalDate }
        set { internalDate = newValue }
    }

    /// Checks if the message is a forwarded email by looking for forward indicators
    var isForwardedEmail: Bool {
        // Check subject line for "FW:" or "Fwd:" prefix
        if let subject = subject, !subject.isEmpty {
            let subjectLower = subject.lowercased()
            if subjectLower.hasPrefix("fwd:") ||
               subjectLower.hasPrefix("fw:") ||
               subjectLower.contains("fwd:") ||
               subjectLower.contains("fw:") {
                return true
            }
        }

        // Check body content for strong forward indicators
        let bodyText = [snippet, cleanedSnippet].compactMap { $0 }.joined(separator: " ")

        let strongForwardIndicators = [
            "Begin forwarded message:",
            "---------- Forwarded message",
            "------ Original Message ------",
            "-----Original Message-----",
            "Forwarded message from"
        ]

        for indicator in strongForwardIndicators {
            if bodyText.range(of: indicator, options: .caseInsensitive) != nil {
                return true
            }
        }

        return false
    }
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

// MARK: - Attachment

extension Attachment {
    @nonobjc public class func fetchRequest() -> NSFetchRequest<Attachment> {
        return NSFetchRequest<Attachment>(entityName: "Attachment")
    }

    @NSManaged public var id: String?
    @NSManaged public var filename: String
    @NSManaged public var mimeType: String
    @NSManaged public var stateRaw: String
    @NSManaged public var localURL: String?
    @NSManaged public var previewURL: String?
    @NSManaged public var byteSize: Int64
    @NSManaged public var pageCount: Int16
    @NSManaged public var width: Int16
    @NSManaged public var height: Int16
    @NSManaged public var message: Message?

    /// Whether this is a locally-created attachment (not yet synced)
    var isLocalAttachment: Bool {
        id?.starts(with: "local_") == true
    }
}

// MARK: - PendingAction

extension PendingAction {
    @nonobjc public class func fetchRequest() -> NSFetchRequest<PendingAction> {
        return NSFetchRequest<PendingAction>(entityName: "PendingAction")
    }

    @NSManaged public var id: UUID
    @NSManaged public var actionType: String
    @NSManaged public var status: String
    @NSManaged public var messageId: String?
    @NSManaged public var conversationId: UUID?
    @NSManaged public var payload: String?
    @NSManaged public var retryCount: Int16
    @NSManaged public var createdAt: Date
    @NSManaged public var lastAttempt: Date?
}