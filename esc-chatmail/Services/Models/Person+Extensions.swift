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
    // No `messageParticipations`: model 9 dropped the inverse of
    // `MessageParticipant.person` (architecture review 2026-11, data-model#3).
    // For the user's own Person it was every message of the mailbox, read
    // into every context that wrote one participant row. A person's message
    // participations are fetched (`DataCleanupService.messageParticipations`);
    // never add the inverse back.

    var name: String? {
        return displayName
    }
}
