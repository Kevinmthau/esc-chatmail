import Foundation
import CoreData

/// Extension containing message batch operations for CoreDataBatchOperations.
extension CoreDataBatchOperations {

    // MARK: - Batch Insert for Messages

    /// Batch inserts messages with duplicate detection and chunked processing.
    /// - Parameters:
    ///   - messages: The processed messages to insert
    ///   - configuration: Batch operation configuration
    func batchInsertMessages(_ messages: [ProcessedMessage], configuration: BatchConfiguration = .default) async throws {
        guard !messages.isEmpty else { return }

        let context = configuration.useBackgroundQueue ?
            coreDataStack.newBackgroundContext() :
            coreDataStack.viewContext

        // Configure context for batch operations
        context.undoManager = nil
        context.shouldDeleteInaccessibleFaults = true
        context.automaticallyMergesChangesFromParent = false

        // Track performance
        let startTime = Date()
        var insertedCount = 0

        try await context.perform {
            // Process in chunks to avoid memory issues
            for chunk in messages.chunked(into: configuration.batchSize) {
                // Check for existing messages to avoid duplicates
                let messageIds = chunk.map { $0.id }
                let existingRequest = NSFetchRequest<Message>(entityName: "Message")
                existingRequest.predicate = MessagePredicates.ids(messageIds)
                existingRequest.resultType = .dictionaryResultType
                existingRequest.propertiesToFetch = ["id"]

                let existingResults = try context.fetch(existingRequest) as? [[String: String]] ?? []
                let existingIds = Set(existingResults.compactMap { $0["id"] })

                // Insert only new messages
                for processedMessage in chunk where !existingIds.contains(processedMessage.id) {
                    let message = Message(context: context)
                    self.mapProcessedToManagedMessage(processedMessage, to: message)
                    insertedCount += 1
                }

                // Save at intervals to prevent memory buildup
                if insertedCount % configuration.saveInterval == 0 {
                    try self.saveContextWithRetry(context)
                    context.reset() // Clear memory after save
                }
            }

            // Final save for remaining messages
            if context.hasChanges {
                try self.saveContextWithRetry(context)
            }
        }

        // Log performance metrics
        let duration = Date().timeIntervalSince(startTime)
        performanceMonitor.log(operation: "batchInsertMessages",
                              count: insertedCount,
                              duration: duration)

        Log.info("Batch inserted \(insertedCount) messages in \(String(format: "%.2f", duration))s", category: .coreData)
    }

    // MARK: - Batch Update for Messages

    /// Batch updates messages with the specified changes.
    /// - Parameters:
    ///   - updates: Array of message IDs and their changes
    ///   - configuration: Batch operation configuration
    func batchUpdateMessages(with updates: [(id: String, changes: [String: Any])], configuration: BatchConfiguration = .default) async throws {
        guard !updates.isEmpty else { return }

        let context = configuration.useBackgroundQueue ?
            coreDataStack.newBackgroundContext() :
            coreDataStack.viewContext

        context.undoManager = nil
        context.automaticallyMergesChangesFromParent = false

        var updatedCount = 0

        try await context.perform {
            for chunk in updates.chunked(into: configuration.batchSize) {
                // Fetch messages to update
                let messageIds = chunk.map { $0.id }
                let request = NSFetchRequest<Message>(entityName: "Message")
                request.predicate = MessagePredicates.ids(messageIds)
                request.returnsObjectsAsFaults = false

                let messages = try context.fetch(request)
                let messageDict = Dictionary(uniqueKeysWithValues: messages.map { ($0.id, $0) })

                // Apply updates
                for (id, changes) in chunk {
                    guard let message = messageDict[id] else { continue }

                    for (key, value) in changes {
                        message.setValue(value, forKey: key)
                    }
                    updatedCount += 1
                }

                // Save at intervals
                if updatedCount % configuration.saveInterval == 0 {
                    try self.saveContextWithRetry(context)
                }
            }

            // Final save
            if context.hasChanges {
                try self.saveContextWithRetry(context)
            }
        }

        Log.info("Batch updated \(updatedCount) messages", category: .coreData)
    }

    // MARK: - Batch Delete for Messages

    /// Batch deletes messages using NSBatchDeleteRequest for efficiency.
    /// - Parameters:
    ///   - messageIds: IDs of messages to delete
    ///   - configuration: Batch operation configuration
    func batchDeleteMessages(withIds messageIds: [String], configuration: BatchConfiguration = .default) async throws {
        guard !messageIds.isEmpty else { return }

        let context = configuration.useBackgroundQueue ?
            coreDataStack.newBackgroundContext() :
            coreDataStack.viewContext

        try await context.perform {
            // Use NSBatchDeleteRequest for efficiency
            let fetchRequest = NSFetchRequest<NSFetchRequestResult>(entityName: "Message")
            fetchRequest.predicate = MessagePredicates.ids(messageIds)
            let deleteRequest = NSBatchDeleteRequest(fetchRequest: fetchRequest)

            // Configure to merge changes
            deleteRequest.resultType = .resultTypeObjectIDs

            let result = try context.execute(deleteRequest) as? NSBatchDeleteResult
            guard let objectIDs = result?.result as? [NSManagedObjectID] else { return }

            // Merge changes to other contexts
            let changes = [NSDeletedObjectsKey: objectIDs]
            NSManagedObjectContext.mergeChanges(
                fromRemoteContextSave: changes,
                into: [self.coreDataStack.viewContext]
            )
        }

        Log.info("Batch deleted \(messageIds.count) messages", category: .coreData)
    }
}
