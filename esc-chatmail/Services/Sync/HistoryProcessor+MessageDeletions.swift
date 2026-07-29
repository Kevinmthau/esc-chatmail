import Foundation
import CoreData

extension HistoryProcessor {
    /// Applies Gmail-side deletions locally. Throws on Core Data failure —
    /// a lost deletion is indistinguishable from "no local rows matched", so
    /// swallowing the error would let the cursor advance past deletions that
    /// were never applied, leaving permanent ghosts.
    func processMessageDeletions(
        _ messagesDeleted: [HistoryMessageDeleted]?,
        modificationTransaction: ModificationTracker.Transaction?,
        in context: NSManagedObjectContext
    ) async throws {
        guard let messagesDeleted = messagesDeleted, !messagesDeleted.isEmpty else { return }

        let messageIds = Set(messagesDeleted.map { $0.message.id })

        let modifiedObjectIDs: [NSManagedObjectID] = try await context.perform {
            // Batch fetch all messages in a single query (avoids N+1 queries)
            let request = Message.fetchRequest()
            request.predicate = NSPredicate(format: "id IN %@", messageIds)
            request.fetchBatchSize = 100
            request.relationshipKeyPathsForPrefetching = ["conversation"]

            var objectIDs: [NSManagedObjectID] = []

            let messages = try context.fetch(request)
            for message in messages {
                // Track conversation BEFORE deletion for rollup updates
                if let conversationID = message.conversation?.objectID {
                    objectIDs.append(conversationID)
                }
                context.delete(message)
            }

            return objectIDs
        }

        // Track modified conversations for rollup updates
        if !modifiedObjectIDs.isEmpty {
            await ModificationTracker.shared.trackModifiedConversations(
                modifiedObjectIDs,
                in: modificationTransaction
            )
        }
    }
}
