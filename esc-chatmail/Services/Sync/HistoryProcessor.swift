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
        syncStartTime: Date? = nil,
        modificationTransaction: ModificationTracker.Transaction?
    ) async throws {
        // Handle message deletions - always apply, deletions are authoritative
        try await processMessageDeletions(
            record.messagesDeleted,
            modificationTransaction: modificationTransaction,
            in: context
        )

        // Handle label additions with conflict resolution
        try await processLabelAdditions(
            record.labelsAdded,
            in: context,
            syncStartTime: syncStartTime,
            modificationTransaction: modificationTransaction
        )

        // Handle label removals with conflict resolution
        try await processLabelRemovals(
            record.labelsRemoved,
            in: context,
            syncStartTime: syncStartTime,
            modificationTransaction: modificationTransaction
        )
    }

    /// Extracts message IDs that need to be fetched from history records
    /// - Parameter records: Array of history records
    /// - Returns: Set of unique message IDs (excluding spam), deduplicated across records
    nonisolated func extractNewMessageIds(
        from records: [HistoryRecord],
        includingExcludedMessageIDs: Set<String> = []
    ) -> Set<String> {
        var messageIds: Set<String> = []

        for record in records {
            if let messagesAdded = record.messagesAdded {
                Log.debug("History record \(record.id): \(messagesAdded.count) new messages", category: .sync)
                for added in messagesAdded {
                    if let labelIds = added.message.labelIds,
                       let excludedMailboxLabel = labelIds.first(
                           where: MessagePersister.excludedMailboxLabelIDs.contains
                       ),
                       !includingExcludedMessageIDs.contains(added.message.id) {
                        Log.debug(
                            "Skipping \(excludedMailboxLabel.lowercased()): \(added.message.id)",
                            category: .sync
                        )
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

    /// Selects excluded-mailbox arrivals that still need a full fetch to
    /// converge an optimistic send. Exact Gmail IDs are cheap to recognize.
    /// A retained local marker has no Gmail ID yet, so its deterministic RFC
    /// Message-ID must be inspected by MessagePersister; only while such a
    /// marker exists do we admit the page's other excluded candidates.
    nonisolated static func excludedRemoteSendEchoMessageIDs(
        from records: [HistoryRecord],
        in context: NSManagedObjectContext
    ) async throws -> Set<String> {
        let excludedMessageIDs = Set(records.flatMap { record in
            (record.messagesAdded ?? []).compactMap { added -> String? in
                guard let labelIDs = added.message.labelIds,
                      labelIDs.contains(where: MessagePersister.excludedMailboxLabelIDs.contains) else {
                    return nil
                }
                return added.message.id
            }
        })
        guard !excludedMessageIDs.isEmpty else { return [] }

        return try await context.perform {
            let markerIDs = [
                OutboundSendRemoteState.inFlightMessageID,
                OutboundSendRemoteState.ambiguousMessageID
            ]
            let request = OutboundSendMutationRecord.fetchRequest()
            request.predicate = NSCompoundPredicate(
                orPredicateWithSubpredicates: [
                    NSPredicate(
                        format: "remoteCommittedMessageId IN %@",
                        Array(excludedMessageIDs)
                    ),
                    NSPredicate(
                        format: "remoteCommittedMessageId IN %@",
                        markerIDs
                    )
                ]
            )
            request.includesPendingChanges = true

            let mutationRecords = try context.fetch(request)
            let exactRemoteMessageIDs = Set<String>(mutationRecords.compactMap { record in
                guard let remoteMessageID = record.remoteCommittedMessageId,
                      excludedMessageIDs.contains(remoteMessageID) else {
                    return nil
                }
                return remoteMessageID
            })
            guard mutationRecords.contains(where: {
                guard let messageID = $0.remoteCommittedMessageId else { return false }
                return markerIDs.contains(messageID)
            }) else {
                return exactRemoteMessageIDs
            }

            return excludedMessageIDs
        }
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
