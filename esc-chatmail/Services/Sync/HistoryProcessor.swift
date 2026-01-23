import Foundation
import CoreData

/// Handles processing Gmail history records for incremental sync
actor HistoryProcessor {
    let coreDataStack: CoreDataStack

    init(coreDataStack: CoreDataStack = .shared) {
        self.coreDataStack = coreDataStack
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
    /// - Returns: Set of unique message IDs (excluding spam), deduplicated across records
    nonisolated func extractNewMessageIds(from records: [HistoryRecord]) -> Set<String> {
        var messageIds: Set<String> = []

        for record in records {
            if let messagesAdded = record.messagesAdded {
                Log.debug("History record \(record.id): \(messagesAdded.count) new messages", category: .sync)
                for added in messagesAdded {
                    // Skip spam messages
                    if let labelIds = added.message.labelIds, labelIds.contains("SPAM") {
                        Log.debug("Skipping spam: \(added.message.id)", category: .sync)
                        continue
                    }
                    // Skip draft messages
                    if let labelIds = added.message.labelIds, labelIds.contains("DRAFT") {
                        Log.debug("Skipping draft: \(added.message.id)", category: .sync)
                        continue
                    }
                    Log.debug("Will fetch: \(added.message.id)", category: .sync)
                    messageIds.insert(added.message.id)
                }
            }
        }

        Log.debug("Total unique messages to fetch: \(messageIds.count)", category: .sync)
        return messageIds
    }

    /// Clear localModifiedAt for messages whose pending actions have been processed
    func clearLocalModifications(for messageIds: [String]) async {
        guard !messageIds.isEmpty else { return }

        let context = coreDataStack.newBackgroundContext()
        await context.perform {
            // Batch fetch all messages at once to avoid N+1 queries
            let request = Message.fetchRequest()
            request.predicate = NSPredicate(format: "id IN %@", messageIds)
            request.fetchBatchSize = 100

            do {
                let messages = try context.fetch(request)
                for message in messages {
                    message.setValue(nil, forKey: "localModifiedAt")
                }

                if context.hasChanges {
                    try context.save()
                    Log.debug("Cleared local modifications for \(messages.count) messages", category: .sync)
                }
            } catch {
                Log.error("Failed to clear local modifications for \(messageIds.count) messages", category: .sync, error: error)
            }
        }
    }
}
