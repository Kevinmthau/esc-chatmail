import Foundation
import CoreData

// MARK: - Empty Entity Cleanup

extension DataCleanupService {

    /// Removes conversations that have no messages and no participants.
    func removeEmptyConversations(in context: NSManagedObjectContext) async {
        let startTime = CFAbsoluteTimeGetCurrent()

        await context.perform {
            let request = NSFetchRequest<NSFetchRequestResult>(entityName: "Conversation")
            request.predicate = ConversationPredicates.empty
            request.resultType = .managedObjectIDResultType

            do {
                guard let objectIDs = try context.fetch(request) as? [NSManagedObjectID],
                      !objectIDs.isEmpty else {
                    return
                }

                let batchDeleteRequest = NSBatchDeleteRequest(objectIDs: objectIDs)
                batchDeleteRequest.resultType = .resultTypeObjectIDs

                let result = try context.execute(batchDeleteRequest) as? NSBatchDeleteResult
                if let deletedIDs = result?.result as? [NSManagedObjectID] {
                    let changes = [NSDeletedObjectsKey: deletedIDs]
                    NSManagedObjectContext.mergeChanges(
                        fromRemoteContextSave: changes,
                        into: [self.coreDataStack.viewContext]
                    )

                    let duration = CFAbsoluteTimeGetCurrent() - startTime
                    Log.info("Removed \(deletedIDs.count) empty conversations in \(String(format: "%.3f", duration))s", category: .coreData)
                }
            } catch {
                Log.error("Failed to batch delete empty conversations", category: .coreData, error: error)
                self.removeEmptyConversationsFallback(in: context)
            }
        }
    }

    /// Fallback for removing empty conversations when batch delete fails.
    internal func removeEmptyConversationsFallback(in context: NSManagedObjectContext) {
        let request = Conversation.fetchRequest()
        request.fetchBatchSize = 50

        guard let conversations = try? context.fetch(request) else { return }

        var removedCount = 0
        for conversation in conversations {
            let hasParticipants = (conversation.participants?.count ?? 0) > 0
            let hasMessages = (conversation.messages?.count ?? 0) > 0

            if !hasParticipants && !hasMessages {
                context.delete(conversation)
                removedCount += 1
            }
        }

        if removedCount > 0 {
            Log.info("Removed \(removedCount) empty conversations (fallback)", category: .coreData)
            coreDataStack.saveIfNeeded(context: context)
        }
    }

    /// Removes all draft messages from the database.
    func removeDraftMessages(in context: NSManagedObjectContext) async {
        let startTime = CFAbsoluteTimeGetCurrent()

        await context.perform {
            let fetchRequest = NSFetchRequest<NSFetchRequestResult>(entityName: "Message")
            fetchRequest.predicate = MessagePredicates.drafts

            let batchDeleteRequest = NSBatchDeleteRequest(fetchRequest: fetchRequest)
            batchDeleteRequest.resultType = .resultTypeCount

            do {
                let result = try context.execute(batchDeleteRequest) as? NSBatchDeleteResult
                let deletedCount = result?.result as? Int ?? 0

                if deletedCount > 0 {
                    context.reset()

                    let duration = CFAbsoluteTimeGetCurrent() - startTime
                    Log.info("Removed \(deletedCount) draft messages in \(String(format: "%.3f", duration))s", category: .coreData)
                }
            } catch {
                Log.error("Failed to batch delete draft messages", category: .coreData, error: error)
                self.removeDraftMessagesFallback(in: context)
            }
        }
    }

    /// Fallback for removing draft messages when batch delete fails.
    internal func removeDraftMessagesFallback(in context: NSManagedObjectContext) {
        let request = Message.fetchRequest()
        request.predicate = MessagePredicates.drafts
        request.fetchBatchSize = 50

        guard let draftMessages = try? context.fetch(request) else { return }

        var removedCount = 0
        for message in draftMessages {
            context.delete(message)
            removedCount += 1
        }

        if removedCount > 0 {
            Log.info("Removed \(removedCount) draft messages (fallback)", category: .coreData)
            coreDataStack.saveIfNeeded(context: context)
        }
    }
}
