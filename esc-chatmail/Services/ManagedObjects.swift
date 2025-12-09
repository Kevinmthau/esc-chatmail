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
        get {
            let stateRawValue = value(forKey: "stateRaw") as? String ?? "queued"
            return State(rawValue: stateRawValue) ?? .queued
        }
        set {
            setValue(newValue.rawValue, forKey: "stateRaw")
        }
    }
    
    var isImage: Bool {
        let mimeTypeValue = value(forKey: "mimeType") as? String
        return mimeTypeValue?.starts(with: "image/") ?? false
    }
    
    var isPDF: Bool {
        let mimeTypeValue = value(forKey: "mimeType") as? String
        return mimeTypeValue == "application/pdf"
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
        case deleteConversation = "deleteConversation"
    }

    enum Status: String {
        case pending = "pending"
        case processing = "processing"
        case failed = "failed"
        case completed = "completed"
    }

    var actionTypeEnum: ActionType? {
        get {
            guard let rawValue = value(forKey: "actionType") as? String else { return nil }
            return ActionType(rawValue: rawValue)
        }
        set {
            setValue(newValue?.rawValue, forKey: "actionType")
        }
    }

    var statusEnum: Status {
        get {
            let rawValue = value(forKey: "status") as? String ?? "pending"
            return Status(rawValue: rawValue) ?? .pending
        }
        set {
            setValue(newValue.rawValue, forKey: "status")
        }
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