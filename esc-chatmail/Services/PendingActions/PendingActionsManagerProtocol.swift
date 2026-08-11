import Foundation
import CoreData

/// Protocol for PendingActionsManager to enable testing with mock implementations.
///
/// This protocol defines the public interface for managing pending actions
/// that need to be synced to Gmail when network is available.
protocol PendingActionsManagerProtocol: Actor {
    /// Queues an action for a single message.
    /// - Parameters:
    ///   - type: The type of action to perform
    ///   - messageId: The Gmail message ID
    ///   - payload: Optional additional data for the action
    func queueAction(type: PendingAction.ActionType, messageId: String, payload: [String: Any]?) async

    /// Queues an action while the caller owns the shared account-work run.
    /// This keeps an optimistic local mutation and its durable enqueue inside
    /// one teardown boundary without recursively acquiring the coordinator.
    func queueAction(
        type: PendingAction.ActionType,
        messageId: String,
        payload: [String: Any]?,
        within syncRun: SyncRun
    ) async

    /// Queues an action for an entire conversation (multiple messages).
    /// - Parameters:
    ///   - type: The type of action to perform
    ///   - sourceConversationId: Local conversation metadata for tracing/debugging only.
    ///     Execution for batch actions is driven by `messageIds`.
    ///   - messageIds: The Gmail message IDs in the conversation
    func queueConversationAction(type: PendingAction.ActionType, sourceConversationId: UUID, messageIds: [String]) async

    /// Conversation-action counterpart to `queueAction(...within:)`.
    func queueConversationAction(
        type: PendingAction.ActionType,
        sourceConversationId: UUID,
        messageIds: [String],
        within syncRun: SyncRun
    ) async

    /// Processes all pending actions that are ready to be synced.
    /// Called automatically when network becomes available.
    func processAllPendingActions() async

    /// Returns the count of pending or failed actions that haven't exceeded retry limit.
    func pendingActionCount() async -> Int

    /// Checks if there's a pending action for a specific message and type.
    /// - Parameters:
    ///   - messageId: The Gmail message ID
    ///   - type: The action type to check for
    /// - Returns: true if a matching pending action exists
    func hasPendingAction(forMessageId messageId: String, type: PendingAction.ActionType) async -> Bool

    /// Cancels a pending action for a specific message and type.
    /// Only cancels actions with "pending" status (not already processing).
    /// - Parameters:
    ///   - messageId: The Gmail message ID
    ///   - type: The action type to cancel
    func cancelPendingAction(forMessageId messageId: String, type: PendingAction.ActionType) async

    /// Stops network monitoring and cleans up resources.
    func stopMonitoring()

    // MARK: - Abandoned Action Management

    /// Returns the count of permanently failed (abandoned) actions.
    func abandonedActionCount() async -> Int

    /// Returns all permanently failed (abandoned) actions.
    func fetchAbandonedActions() async -> [AbandonedActionInfo]

    /// Retries an abandoned action by resetting its status and retry count.
    func retryAbandonedAction(objectID: NSManagedObjectID) async

    /// Retries all abandoned actions by resetting their status and retry count.
    func retryAllAbandonedActions() async

    /// Dismisses (deletes) an abandoned action permanently.
    func dismissAbandonedAction(objectID: NSManagedObjectID) async

    /// Dismisses (deletes) all abandoned actions permanently.
    func dismissAllAbandonedActions() async
}

extension PendingActionsManagerProtocol {
    func queueAction(
        type: PendingAction.ActionType,
        messageId: String,
        payload: [String: Any]?,
        within _: SyncRun
    ) async {
        await queueAction(type: type, messageId: messageId, payload: payload)
    }

    func queueConversationAction(
        type: PendingAction.ActionType,
        sourceConversationId: UUID,
        messageIds: [String],
        within _: SyncRun
    ) async {
        await queueConversationAction(
            type: type,
            sourceConversationId: sourceConversationId,
            messageIds: messageIds
        )
    }
}
