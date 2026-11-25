import CoreData
import Foundation

/// Which messages a pending action changes in Gmail, read the same way by the
/// processor (which clears a completed action's local markers only where no
/// other live action still names the message) and by label reconciliation
/// (which leaves a message alone while a live action names it).
enum PendingActionTargets {
    /// The statuses of an action still to be sent. `abandoned` and
    /// `completed` are not: an abandoned action has given up, and a local
    /// change it described is the 30-minute marker's alone.
    static let liveStatuses = ["pending", "processing", "failed"]

    static func messageIDs(
        actionType: PendingAction.ActionType?,
        messageId: String?,
        payload: [String: Any]?
    ) -> Set<String> {
        var directMessageIDs = Set<String>()
        if let messageId, !messageId.isEmpty {
            directMessageIDs.insert(messageId)
        }
        let payloadMessageIDs = Set(
            (payload?["messageIds"] as? [String] ?? []).filter { !$0.isEmpty }
        )

        guard let actionType else {
            // An invalid live row will be abandoned when processed. Until
            // then, retain every marker it might plausibly describe.
            return directMessageIDs.union(payloadMessageIDs)
        }

        switch actionType {
        case .markRead:
            return payloadMessageIDs.isEmpty ? directMessageIDs : payloadMessageIDs
        case .archiveConversation, .reportSpam:
            return payloadMessageIDs
        case .markUnread, .archive, .star, .unstar:
            return directMessageIDs
        }
    }

    static func messageIDs(
        actionType: PendingAction.ActionType?,
        messageId: String?,
        payloadString: String?
    ) -> Set<String> {
        let payload: [String: Any]?
        if let payloadString,
           let data = payloadString.data(using: .utf8) {
            payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        } else {
            payload = nil
        }
        return messageIDs(actionType: actionType, messageId: messageId, payload: payload)
    }

    /// Every message a live action still has to change in Gmail. Call inside
    /// the context's `perform`. A failed read throws: it is never "no live
    /// actions", which would let reconciliation undo a change still queued.
    static func liveTargetMessageIDs(in context: NSManagedObjectContext) throws -> Set<String> {
        let request = NSFetchRequest<NSDictionary>(entityName: "PendingAction")
        request.resultType = .dictionaryResultType
        request.propertiesToFetch = ["actionType", "messageId", "payload"]
        request.predicate = NSPredicate(format: "status IN %@", liveStatuses)
        var targets = Set<String>()
        for row in try context.fetch(request) {
            targets.formUnion(messageIDs(
                actionType: (row["actionType"] as? String).flatMap(PendingAction.ActionType.init(rawValue:)),
                messageId: row["messageId"] as? String,
                payloadString: row["payload"] as? String
            ))
        }
        return targets
    }
}
