import Foundation
import CoreData

@objc(Account)
public class Account: NSManagedObject {
}

@objc(Attachment)
public class Attachment: NSManagedObject, Identifiable {
}

@objc(Person)  
public class Person: NSManagedObject, Identifiable {
}

@objc(Conversation)
public class Conversation: NSManagedObject, Identifiable {
}

@objc(ConversationParticipant)
public class ConversationParticipant: NSManagedObject, Identifiable {
}

@objc(Message)
public class Message: NSManagedObject, Identifiable {
}

@objc(MessageParticipant)
public class MessageParticipant: NSManagedObject, Identifiable {
}

@objc(Label)
public class Label: NSManagedObject, Identifiable {
}

@objc(PendingAction)
public class PendingAction: NSManagedObject, Identifiable {
}

@objc(OutboundSendMutationRecord)
public class OutboundSendMutationRecord: NSManagedObject, Identifiable {
}

@objc(AbandonedSyncMessage)
public class AbandonedSyncMessage: NSManagedObject, Identifiable {
}

@objc(SyncCheckpoint)
public class SyncCheckpoint: NSManagedObject, Identifiable {
}

extension Attachment {
    enum State: String {
        case queued = "queued"
        case uploading = "uploading"
        case uploaded = "uploaded"
        case failed = "failed"
        case downloaded = "downloaded"
    }

    var state: State {
        get { State(rawValue: stateRaw) ?? .queued }
        set { stateRaw = newValue.rawValue }
    }

    var isImage: Bool {
        mimeType.starts(with: "image/")
    }

    var isVideo: Bool {
        mimeType.starts(with: "video/")
    }

    var isPDF: Bool {
        mimeType == "application/pdf"
    }

    var isDownloaded: Bool {
        state == .downloaded || state == .uploaded
    }

    var isReady: Bool {
        state == .downloaded || state == .uploaded
    }
}

extension PendingAction {
    enum ActionType: String {
        case markRead = "markRead"
        case markUnread = "markUnread"
        case archive = "archive"
        case archiveConversation = "archiveConversation"
        case star = "star"
        case unstar = "unstar"
        case reportSpam = "reportSpam"
    }

    enum Status: String {
        case pending = "pending"
        case processing = "processing"
        case failed = "failed"
        case completed = "completed"
        case abandoned = "abandoned"
    }

    var actionTypeEnum: ActionType? {
        get { ActionType(rawValue: actionType) }
        set { actionType = newValue?.rawValue ?? "" }
    }

    var statusEnum: Status {
        get { Status(rawValue: status) ?? .pending }
        set { status = newValue.rawValue }
    }
}

extension OutboundSendMutationRecord {
    @nonobjc public class func fetchRequest() -> NSFetchRequest<OutboundSendMutationRecord> {
        NSFetchRequest<OutboundSendMutationRecord>(entityName: "OutboundSendMutationRecord")
    }

    @NSManaged public var archivedAt: Date?
    @NSManaged public var conversationId: UUID?
    @NSManaged public var conversationURI: String?
    @NSManaged public var createdAt: Date
    @NSManaged public var displayName: String?
    @NSManaged public var hidden: Bool
    @NSManaged public var id: String
    @NSManaged public var lastMessageDate: Date?
    @NSManaged public var newlyInsertedConversation: Bool
    @NSManaged public var remoteCommittedMessageId: String?
    @NSManaged public var remoteCommittedThreadId: String?
    @NSManaged public var snippet: String?
}

extension Message {
    func addToLabels(_ value: Label) {
        let items = self.mutableSetValue(forKey: "labels")
        items.add(value)
    }
    
    func removeFromLabels(_ value: Label) {
        let items = self.mutableSetValue(forKey: "labels")
        items.remove(value)
    }
    
    func addToAttachments(_ value: Attachment) {
        let items = self.mutableSetValue(forKey: "attachments")
        items.add(value)
    }
    
    func removeFromAttachments(_ value: Attachment) {
        let items = self.mutableSetValue(forKey: "attachments")
        items.remove(value)
    }
}
