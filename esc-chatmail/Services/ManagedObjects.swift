import Foundation
import CoreData

@objc(Account)
public class Account: NSManagedObject {
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

extension Message {
    func addToLabels(_ value: Label) {
        let items = self.mutableSetValue(forKey: "labels")
        items.add(value)
    }
    
    func removeFromLabels(_ value: Label) {
        let items = self.mutableSetValue(forKey: "labels")
        items.remove(value)
    }
}