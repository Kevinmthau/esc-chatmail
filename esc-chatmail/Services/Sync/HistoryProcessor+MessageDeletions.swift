import Foundation
import CoreData

extension HistoryProcessor {
    func processMessageDeletions(
        _ messagesDeleted: [HistoryMessageDeleted]?,
        in context: NSManagedObjectContext
    ) async {
        guard let messagesDeleted = messagesDeleted, !messagesDeleted.isEmpty else { return }

        let messageIds = Set(messagesDeleted.map { $0.message.id })

        let modifiedObjectIDs: [NSManagedObjectID] = await context.perform {
            // Batch fetch all messages in a single query (avoids N+1 queries)
            let request = Message.fetchRequest()
            request.predicate = NSPredicate(format: "id IN %@", messageIds)
            request.fetchBatchSize = 100
            request.relationshipKeyPathsForPrefetching = ["conversation"]

            var objectIDs: [NSManagedObjectID] = []

            do {
                let messages = try context.fetch(request)
                for message in messages {
                    // Track conversation BEFORE deletion for rollup updates
                    if let conversationID = message.conversation?.objectID {
                        objectIDs.append(conversationID)
                    }
                    context.delete(message)
                }
            } catch {
                Log.error("Failed to batch fetch messages for deletion", category: .sync, error: error)
            }

            return objectIDs
        }

        // Track modified conversations for rollup updates
        if !modifiedObjectIDs.isEmpty {
            await trackModifiedConversations(modifiedObjectIDs)
        }
    }
}
