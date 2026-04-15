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

        // Track all modified conversations
        await ModificationTracker.shared.trackModifiedConversations(modifiedObjectIDs)
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

        // Track all modified conversations
        await ModificationTracker.shared.trackModifiedConversations(modifiedObjectIDs)
    }

    /// Check if a message has local modifications that haven't been synced yet
    /// Note: This method is kept for use by other components (e.g., SyncReconciliation, LabelOperationProcessor)
    nonisolated static func hasPendingLocalModification(message: Message) -> Bool {
        guard let localModifiedAt = message.localModifiedAtValue else { return false }

        let now = Date()
        let modificationAge = now.timeIntervalSince(localModifiedAt)
        let isStaleModification = modificationAge > Self.maxLocalModificationAge

        if isStaleModification {
            Log.warning(
                "Local modification is stale (age: \(Int(modificationAge))s), allowing server update",
                category: .sync
            )
            return false
        }

        return true
    }

    /// Check if a message has local modifications that haven't been synced yet
    /// Note: `syncStartTime` is retained for call-site compatibility, but any fresh pending
    /// local mutation should block server label/unread writes until it is synced or expires.
    nonisolated static func hasConflict(message: Message, syncStartTime: Date?) -> Bool {
        _ = syncStartTime
        return hasPendingLocalModification(message: message)
    }
}
