import Foundation
import CoreData

/// Handles processing Gmail history records for incremental sync
actor HistoryProcessor {
    let coreDataStack: CoreDataStack

    /// Tracks conversation IDs modified during history processing
    /// Actor isolation provides thread safety
    private var modifiedConversationIDs: Set<NSManagedObjectID> = []

    init(coreDataStack: CoreDataStack = .shared) {
        self.coreDataStack = coreDataStack
    }

    /// Returns and clears the set of modified conversation IDs
    func getAndClearModifiedConversations() -> Set<NSManagedObjectID> {
        let result = modifiedConversationIDs
        modifiedConversationIDs.removeAll()
        return result
    }

    /// Tracks a conversation as modified by its objectID
    func trackModifiedConversation(_ objectID: NSManagedObjectID) {
        modifiedConversationIDs.insert(objectID)
    }

    /// Tracks multiple conversations as modified
    func trackModifiedConversations(_ objectIDs: [NSManagedObjectID]) {
        for objectID in objectIDs {
            modifiedConversationIDs.insert(objectID)
        }
    }

    /// Tracks a conversation as modified (public version for reconciliation)
    func trackModifiedConversationForReconciliation(_ conversation: Conversation) {
        modifiedConversationIDs.insert(conversation.objectID)
    }

    /// Processes a history record for lightweight operations (label changes and deletions)
    /// - Parameters:
    ///   - record: The history record to process
    ///   - context: The Core Data context
    ///   - syncStartTime: When the sync started (for conflict resolution)
    func processLightweightOperations(
        _ record: HistoryRecord,
        in context: NSManagedObjectContext,
        syncStartTime: Date? = nil
    ) async {
        // Handle message deletions - always apply, deletions are authoritative
        await processMessageDeletions(record.messagesDeleted, in: context)

        // Handle label additions with conflict resolution
        await processLabelAdditions(record.labelsAdded, in: context, syncStartTime: syncStartTime)

        // Handle label removals with conflict resolution
        await processLabelRemovals(record.labelsRemoved, in: context, syncStartTime: syncStartTime)
    }

    /// Extracts message IDs that need to be fetched from history records
    /// - Parameter records: Array of history records
    /// - Returns: Array of message IDs (excluding spam)
    nonisolated func extractNewMessageIds(from records: [HistoryRecord]) -> [String] {
        var messageIds: [String] = []

        for record in records {
            if let messagesAdded = record.messagesAdded {
                Log.debug("History record \(record.id): \(messagesAdded.count) new messages", category: .sync)
                for added in messagesAdded {
                    // Skip spam messages
                    if let labelIds = added.message.labelIds, labelIds.contains("SPAM") {
                        Log.debug("Skipping spam: \(added.message.id)", category: .sync)
                        continue
                    }
                    Log.debug("Will fetch: \(added.message.id)", category: .sync)
                    messageIds.append(added.message.id)
                }
            }
        }

        Log.debug("Total new messages to fetch: \(messageIds.count)", category: .sync)
        return messageIds
    }

    /// Clear localModifiedAt for messages whose pending actions have been processed
    func clearLocalModifications(for messageIds: [String]) async {
        let context = coreDataStack.newBackgroundContext()
        await context.perform {
            var successCount = 0
            for messageId in messageIds {
                let request = Message.fetchRequest()
                request.predicate = NSPredicate(format: "id == %@", messageId)
                do {
                    if let message = try context.fetch(request).first {
                        message.setValue(nil, forKey: "localModifiedAt")
                        successCount += 1
                    }
                } catch {
                    Log.error("Failed to fetch message \(messageId) for clearing local modifications", category: .sync, error: error)
                }
            }

            do {
                if context.hasChanges {
                    try context.save()
                    Log.debug("Cleared local modifications for \(successCount) messages", category: .sync)
                }
            } catch {
                Log.error("Failed to save after clearing local modifications", category: .sync, error: error)
            }
        }
    }
}
