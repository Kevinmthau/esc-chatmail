import Foundation
import CoreData

/// Extension containing conversation batch operations for CoreDataBatchOperations.
extension CoreDataBatchOperations {

    // MARK: - Batch Insert for Conversations

    /// Batch inserts conversations with duplicate detection and chunked processing.
    /// - Parameters:
    ///   - conversations: The processed conversations to insert
    ///   - configuration: Batch operation configuration
    func batchInsertConversations(_ conversations: [ProcessedConversation], configuration: BatchConfiguration = .default) async throws {
        guard !conversations.isEmpty else { return }

        let context = configuration.useBackgroundQueue ?
            coreDataStack.newBackgroundContext() :
            coreDataStack.viewContext

        context.undoManager = nil
        context.automaticallyMergesChangesFromParent = false

        var insertedCount = 0

        try await context.perform {
            for chunk in conversations.chunked(into: configuration.batchSize) {
                // Check existing conversations
                let keyHashes = chunk.map { $0.keyHash }
                let existingRequest = NSFetchRequest<Conversation>(entityName: "Conversation")
                existingRequest.predicate = ConversationPredicates.keyHashes(keyHashes)
                existingRequest.resultType = .dictionaryResultType
                existingRequest.propertiesToFetch = ["keyHash"]

                let existingResults = try context.fetch(existingRequest) as? [[String: String]] ?? []
                let existingHashes = Set(existingResults.compactMap { $0["keyHash"] })

                // Insert only new conversations
                for processedConv in chunk where !existingHashes.contains(processedConv.keyHash) {
                    let conversation = Conversation(context: context)
                    self.mapProcessedToManagedConversation(processedConv, to: conversation)
                    insertedCount += 1
                }

                // Save at intervals
                if insertedCount % configuration.saveInterval == 0 {
                    try self.saveContextWithRetry(context)
                    context.reset()
                }
            }

            // Final save
            if context.hasChanges {
                try self.saveContextWithRetry(context)
            }
        }

        Log.info("Batch inserted \(insertedCount) conversations", category: .coreData)
    }
}
