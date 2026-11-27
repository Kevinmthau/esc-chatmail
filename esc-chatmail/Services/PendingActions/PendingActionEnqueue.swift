import CoreData
import Foundation

/// How a pending action's row is made, in a context of the caller's, and the
/// receipt that says one was.
///
/// `MessageActions` stages the row in the background context that holds the
/// local change the action describes (the archive, the read state, the star),
/// and that context's one save commits both or neither. Until 2026-11-27 the
/// change was saved first and the row was inserted afterwards on the view
/// context by `PendingActionsManager`, in a save of its own that did not roll
/// back: a process killed between the two saves kept a change Gmail never
/// received, and label reconciliation undid it on recent mail once its
/// 30-minute marker had lapsed (architecture review 2026-11,
/// outbound-and-actions#4).
///
/// The receipts have no initializer outside this file, so the manager's
/// `within:` witnesses can be called only with a row that was staged. Hand one
/// on only after the save that commits it has succeeded.
enum PendingActionEnqueue {
    /// A single-message action whose row a caller staged.
    struct StagedMessageAction: Sendable {
        let type: PendingAction.ActionType
        let messageId: String

        fileprivate init(type: PendingAction.ActionType, messageId: String) {
            self.type = type
            self.messageId = messageId
        }
    }

    /// A conversation-wide action whose row a caller staged. Its payload
    /// names `messageIds`; `sourceConversationId` is metadata for tracing.
    struct StagedConversationAction: Sendable {
        let type: PendingAction.ActionType
        let sourceConversationId: UUID
        let messageIds: [String]

        fileprivate init(type: PendingAction.ActionType, sourceConversationId: UUID, messageIds: [String]) {
            self.type = type
            self.sourceConversationId = sourceConversationId
            self.messageIds = messageIds
        }
    }

    /// Inserts a pending row for one message's action into `context`, for the
    /// caller's save. Call inside `context.perform`.
    ///
    /// `createdAt` has no default. The processor clears a completed action's
    /// `localModifiedAt` markers only where they are no later than its
    /// `createdAt` (`clearLocalModifications`), so a caller that stamps
    /// markers passes their own date: a row dated before its markers leaves
    /// them set until they lapse.
    @discardableResult
    static func stageMessageAction(
        type: PendingAction.ActionType,
        messageId: String,
        payload: [String: Any]? = nil,
        createdAt: Date,
        in context: NSManagedObjectContext
    ) -> StagedMessageAction {
        insertRow(
            in: context,
            type: type,
            messageId: messageId,
            sourceConversationId: nil,
            payload: payload,
            createdAt: createdAt
        )
        return StagedMessageAction(type: type, messageId: messageId)
    }

    /// Inserts a pending row for a conversation-wide action into `context`,
    /// for the caller's save. Call inside `context.perform`. `createdAt` as
    /// for `stageMessageAction`.
    @discardableResult
    static func stageConversationAction(
        type: PendingAction.ActionType,
        sourceConversationId: UUID,
        messageIds: [String],
        createdAt: Date,
        in context: NSManagedObjectContext
    ) -> StagedConversationAction {
        insertRow(
            in: context,
            type: type,
            messageId: nil,
            sourceConversationId: sourceConversationId,
            payload: ["messageIds": messageIds],
            createdAt: createdAt
        )
        return StagedConversationAction(
            type: type,
            sourceConversationId: sourceConversationId,
            messageIds: messageIds
        )
    }

    private static func insertRow(
        in context: NSManagedObjectContext,
        type: PendingAction.ActionType,
        messageId: String?,
        sourceConversationId: UUID?,
        payload: [String: Any]?,
        createdAt: Date
    ) {
        let action = PendingAction(context: context)
        action.setValue(UUID(), forKey: "id")
        action.setValue(type.rawValue, forKey: "actionType")
        action.setValue(messageId, forKey: "messageId")
        action.setValue(sourceConversationId, forKey: "conversationId")
        action.setValue(createdAt, forKey: "createdAt")
        action.setValue("pending", forKey: "status")
        action.setValue(Int16(0), forKey: "retryCount")

        if let payload = payload,
           let payloadData = try? JSONSerialization.data(withJSONObject: payload),
           let payloadString = String(data: payloadData, encoding: .utf8) {
            action.setValue(payloadString, forKey: "payload")
        }
    }
}
