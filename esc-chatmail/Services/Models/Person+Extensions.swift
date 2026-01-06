import Foundation
import CoreData

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
