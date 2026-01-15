import Foundation
import CoreData

extension HistoryProcessor {
    /// Maximum age for local modifications before they're considered stale
    /// Uses centralized config from SyncConfig
    static var maxLocalModificationAge: TimeInterval {
        SyncConfig.maxLocalModificationAge
    }

    /// Processes label additions using the shared LabelOperationProcessor
    func processLabelAdditions(
        _ labelsAdded: [HistoryLabelAdded]?,
        in context: NSManagedObjectContext,
        syncStartTime: Date?
    ) async {
        let modifiedObjectIDs = await LabelOperationProcessor.process(
            items: labelsAdded,
            operation: .add,
            in: context,
            syncStartTime: syncStartTime
        )

        // Track all modified conversations (actor-isolated)
        await trackModifiedConversations(modifiedObjectIDs)
    }

    /// Processes label removals using the shared LabelOperationProcessor
    func processLabelRemovals(
        _ labelsRemoved: [HistoryLabelRemoved]?,
        in context: NSManagedObjectContext,
        syncStartTime: Date?
    ) async {
        let modifiedObjectIDs = await LabelOperationProcessor.process(
            items: labelsRemoved,
            operation: .remove,
            in: context,
            syncStartTime: syncStartTime
        )

        // Track all modified conversations (actor-isolated)
        await trackModifiedConversations(modifiedObjectIDs)
    }

    /// Check if a message has local modifications that haven't been synced yet
    /// Note: This method is kept for use by other components (e.g., SyncReconciliation)
    nonisolated func hasConflict(message: Message, syncStartTime: Date?) -> Bool {
        guard let syncStartTime = syncStartTime else { return false }
        guard let localModifiedAt = message.localModifiedAtValue else { return false }

        // If the message was modified locally after the sync started,
        // it means there's a pending local change that should take precedence
        let hasPendingChange = localModifiedAt > syncStartTime

        // However, if the local modification is too old, consider it stale
        // This prevents local changes from blocking server updates indefinitely
        // This can happen if the action failed to sync to the server
        let now = Date()
        let modificationAge = now.timeIntervalSince(localModifiedAt)
        let isStaleModification = modificationAge > Self.maxLocalModificationAge

        if hasPendingChange && isStaleModification {
            Log.warning("Local modification is stale (age: \(Int(modificationAge))s), allowing server update", category: .sync)
            return false
        }

        return hasPendingChange
    }
}
