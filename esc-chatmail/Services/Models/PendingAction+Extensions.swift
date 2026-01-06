import Foundation
import CoreData

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

    /// Type-safe accessor for messageId (alias for consistency)
    var messageIdValue: String? {
        messageId
    }

    /// Type-safe accessor for conversationId (alias for consistency)
    var conversationIdValue: UUID? {
        conversationId
    }

    /// Type-safe accessor for payload (alias for consistency)
    var payloadValue: String? {
        payload
    }

    /// Type-safe accessor for retryCount (alias for consistency)
    var retryCountValue: Int16 {
        retryCount
    }
}
