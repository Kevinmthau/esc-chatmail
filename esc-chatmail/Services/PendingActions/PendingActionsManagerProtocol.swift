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

    /// Tells the manager of an action whose row the caller staged in its own
    /// context (`PendingActionEnqueue.stageMessageAction`) and committed in
    /// the save of the local change it describes, while the caller owns the
    /// shared account-work run. It inserts nothing: it schedules processing.
    /// Call it only after that save succeeded. The row and the change are one
    /// save so that a process killed between two saves can no longer keep a
    /// change Gmail is never told of (architecture review 2026-11,
    /// outbound-and-actions#4).
    ///
    /// A required witness, with no protocol-extension default (neither has its
    /// conversation counterpart below): until 2026-11-27 a default forwarded a
    /// missing or mistyped `within:` witness to the acquiring overload above,
    /// which calls `acquireRun`. `MessageActions` calls this while it holds a
    /// conversation's turn, so the fallback was a silent one that compiled:
    /// with a sync in flight, `acquireRun` parks behind it while sync waits on
    /// the turn, a hang; with none, it takes the exclusive run and skips the
    /// caller's `isActiveRun` guard. The test conformers implemented only the
    /// acquiring overloads, so no test ran the real witnesses (architecture
    /// review 2026-11, invariant-enforcement#2). A conformer that forgets it
    /// now fails to compile.
    func queueAction(
        _ action: PendingActionEnqueue.StagedMessageAction,
        within syncRun: SyncRun
    ) async

    /// Queues an action for an entire conversation (multiple messages).
    /// - Parameters:
    ///   - type: The type of action to perform
    ///   - sourceConversationId: Local conversation metadata for tracing/debugging only.
    ///     Execution for batch actions is driven by `messageIds`.
    ///   - messageIds: The Gmail message IDs in the conversation
    func queueConversationAction(type: PendingAction.ActionType, sourceConversationId: UUID, messageIds: [String]) async

    /// Conversation-action counterpart to `queueAction(_:within:)`, for a row
    /// staged with `PendingActionEnqueue.stageConversationAction`.
    func queueConversationAction(
        _ action: PendingActionEnqueue.StagedConversationAction,
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
