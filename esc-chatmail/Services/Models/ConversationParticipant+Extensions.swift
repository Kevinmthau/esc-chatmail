import Foundation
import CoreData

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
