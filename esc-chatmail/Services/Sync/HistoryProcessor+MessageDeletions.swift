import Foundation
import CoreData

extension HistoryProcessor {
    func processMessageDeletions(
        _ messagesDeleted: [HistoryMessageDeleted]?,
        in context: NSManagedObjectContext
    ) async {
        guard let messagesDeleted = messagesDeleted, !messagesDeleted.isEmpty else { return }

        let messageIds = messagesDeleted.map { $0.message.id }

        let modifiedObjectIDs: [NSManagedObjectID] = await context.perform {
            var objectIDs: [NSManagedObjectID] = []
            for messageId in messageIds {
                let request = Message.fetchRequest()
                request.predicate = NSPredicate(format: "id == %@", messageId)
                request.fetchLimit = 1

                do {
                    if let message = try context.fetch(request).first {
                        // Track conversation BEFORE deletion for rollup updates
                        if let conversationID = message.conversation?.objectID {
                            objectIDs.append(conversationID)
                        }
                        context.delete(message)
                    }
                } catch {
                    Log.error("Failed to fetch message for deletion \(messageId)", category: .sync, error: error)
                }
            }
            return objectIDs
        }

        // Track modified conversations for rollup updates
        if !modifiedObjectIDs.isEmpty {
            trackModifiedConversations(modifiedObjectIDs)
        }
    }
}
