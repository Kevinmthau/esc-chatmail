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
    }

    enum Status: String {
        case pending = "pending"
        case processing = "processing"
        case failed = "failed"
        case completed = "completed"
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