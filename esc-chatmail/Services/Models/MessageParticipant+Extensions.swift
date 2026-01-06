import Foundation
import CoreData

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
