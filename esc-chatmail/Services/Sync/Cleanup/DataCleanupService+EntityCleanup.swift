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
            batchDeleteRequest.resultType = .resultTypeObjectIDs

            do {
                let result = try context.execute(batchDeleteRequest) as? NSBatchDeleteResult
                let deletedIDs = result?.result as? [NSManagedObjectID] ?? []
                let deletedCount = deletedIDs.count

                if deletedCount > 0 {
                    let changes = [NSDeletedObjectsKey: deletedIDs]
                    NSManagedObjectContext.mergeChanges(
                        fromRemoteContextSave: changes,
                        into: [self.coreDataStack.viewContext, context]
                    )

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

    // MARK: - Orphaned Data Cleanup

    /// Removes orphaned PendingActions whose conversation has been deleted.
    /// This can happen if a conversation is deleted while actions are pending.
    func removeOrphanedPendingActions(in context: NSManagedObjectContext) async {
        let startTime = CFAbsoluteTimeGetCurrent()

        await context.perform {
            let request = PendingAction.fetchRequest()
            request.fetchBatchSize = 100

            do {
                let actions = try context.fetch(request)

                // Collect all conversation IDs that need to be checked
                let conversationIds = Set(actions.compactMap { $0.conversationId })
                guard !conversationIds.isEmpty else { return }

                // Single batch fetch to find which conversations exist
                let existingRequest = NSFetchRequest<NSDictionary>(entityName: "Conversation")
                existingRequest.predicate = NSPredicate(format: "id IN %@", conversationIds as CVarArg)
                existingRequest.propertiesToFetch = ["id"]
                existingRequest.resultType = .dictionaryResultType
                let existingResults = try context.fetch(existingRequest)
                let existingIds = Set(existingResults.compactMap { $0["id"] as? UUID })

                // Delete actions whose conversation no longer exists
                var removedCount = 0
                for action in actions {
                    if let conversationId = action.conversationId, !existingIds.contains(conversationId) {
                        Log.debug("Removing orphaned pending action for deleted conversation: \(conversationId)", category: .coreData)
                        context.delete(action)
                        removedCount += 1
                    }
                }

                if removedCount > 0 {
                    try context.save()
                    let duration = CFAbsoluteTimeGetCurrent() - startTime
                    Log.info("Removed \(removedCount) orphaned pending actions in \(String(format: "%.3f", duration))s", category: .coreData)
                }
            } catch {
                Log.error("Failed to cleanup orphaned pending actions", category: .coreData, error: error)
            }
        }
    }

    /// Removes orphaned ConversationParticipant entries that reference non-existent conversations.
    func removeOrphanedConversationParticipants(in context: NSManagedObjectContext) async {
        let startTime = CFAbsoluteTimeGetCurrent()

        await context.perform {
            // Use batch delete for efficiency - find participants where conversation is nil
            let fetchRequest = NSFetchRequest<NSFetchRequestResult>(entityName: "ConversationParticipant")
            fetchRequest.predicate = NSPredicate(format: "conversation == nil")
            fetchRequest.resultType = .managedObjectIDResultType

            do {
                guard let objectIDs = try context.fetch(fetchRequest) as? [NSManagedObjectID],
                      !objectIDs.isEmpty else {
                    return
                }

                let batchDeleteRequest = NSBatchDeleteRequest(objectIDs: objectIDs)
                batchDeleteRequest.resultType = .resultTypeCount

                let result = try context.execute(batchDeleteRequest) as? NSBatchDeleteResult
                let deletedCount = result?.result as? Int ?? 0

                if deletedCount > 0 {
                    let duration = CFAbsoluteTimeGetCurrent() - startTime
                    Log.info("Removed \(deletedCount) orphaned conversation participants in \(String(format: "%.3f", duration))s", category: .coreData)
                }
            } catch {
                Log.error("Failed to cleanup orphaned conversation participants", category: .coreData, error: error)
            }
        }
    }

    /// Removes orphaned MessageParticipant entries that reference non-existent messages.
    func removeOrphanedMessageParticipants(in context: NSManagedObjectContext) async {
        let startTime = CFAbsoluteTimeGetCurrent()

        await context.perform {
            // Use batch delete for efficiency - find participants where message is nil
            let fetchRequest = NSFetchRequest<NSFetchRequestResult>(entityName: "MessageParticipant")
            fetchRequest.predicate = NSPredicate(format: "message == nil")
            fetchRequest.resultType = .managedObjectIDResultType

            do {
                guard let objectIDs = try context.fetch(fetchRequest) as? [NSManagedObjectID],
                      !objectIDs.isEmpty else {
                    return
                }

                let batchDeleteRequest = NSBatchDeleteRequest(objectIDs: objectIDs)
                batchDeleteRequest.resultType = .resultTypeCount

                let result = try context.execute(batchDeleteRequest) as? NSBatchDeleteResult
                let deletedCount = result?.result as? Int ?? 0

                if deletedCount > 0 {
                    let duration = CFAbsoluteTimeGetCurrent() - startTime
                    Log.info("Removed \(deletedCount) orphaned message participants in \(String(format: "%.3f", duration))s", category: .coreData)
                }
            } catch {
                Log.error("Failed to cleanup orphaned message participants", category: .coreData, error: error)
            }
        }
    }

    /// Removes orphaned Message entries that have no conversation.
    /// This can happen if a conversation is deleted but its messages weren't properly cascade-deleted.
    func removeOrphanedMessages(in context: NSManagedObjectContext) async {
        let startTime = CFAbsoluteTimeGetCurrent()

        await context.perform {
            // Use batch delete for efficiency - find messages where conversation is nil
            let fetchRequest = NSFetchRequest<NSFetchRequestResult>(entityName: "Message")
            fetchRequest.predicate = NSPredicate(format: "conversation == nil")
            fetchRequest.resultType = .managedObjectIDResultType

            do {
                guard let objectIDs = try context.fetch(fetchRequest) as? [NSManagedObjectID],
                      !objectIDs.isEmpty else {
                    return
                }

                let batchDeleteRequest = NSBatchDeleteRequest(objectIDs: objectIDs)
                batchDeleteRequest.resultType = .resultTypeCount

                let result = try context.execute(batchDeleteRequest) as? NSBatchDeleteResult
                let deletedCount = result?.result as? Int ?? 0

                if deletedCount > 0 {
                    let duration = CFAbsoluteTimeGetCurrent() - startTime
                    Log.info("Removed \(deletedCount) orphaned messages in \(String(format: "%.3f", duration))s", category: .coreData)
                }
            } catch {
                Log.error("Failed to cleanup orphaned messages", category: .coreData, error: error)
            }
        }
    }

    /// Removes stale Label entities that have no associated messages.
    /// Excludes system labels (INBOX, SENT, etc.) that should always exist.
    func removeStaleLabels(in context: NSManagedObjectContext) async {
        let startTime = CFAbsoluteTimeGetCurrent()

        // System labels that should never be removed
        let systemLabels = Set(["INBOX", "SENT", "TRASH", "DRAFT", "SPAM", "STARRED", "IMPORTANT", "UNREAD", "CATEGORY_PERSONAL", "CATEGORY_SOCIAL", "CATEGORY_PROMOTIONS", "CATEGORY_UPDATES", "CATEGORY_FORUMS"])

        await context.perform {
            let request = Label.fetchRequest()
            request.fetchBatchSize = 50

            do {
                let labels = try context.fetch(request)
                var removedCount = 0

                for label in labels {
                    // Skip system labels
                    guard !systemLabels.contains(label.id) else { continue }

                    // Check if label has any messages
                    let messageCount = label.messages?.count ?? 0
                    if messageCount == 0 {
                        Log.debug("Removing stale label with no messages: \(label.name)", category: .coreData)
                        context.delete(label)
                        removedCount += 1
                    }
                }

                if removedCount > 0 {
                    try context.save()
                    let duration = CFAbsoluteTimeGetCurrent() - startTime
                    Log.info("Removed \(removedCount) stale labels in \(String(format: "%.3f", duration))s", category: .coreData)
                }
            } catch {
                Log.error("Failed to cleanup stale labels", category: .coreData, error: error)
            }
        }
    }

    /// Performs comprehensive orphaned data cleanup.
    /// Call this periodically (e.g., during incremental sync) to maintain database hygiene.
    func cleanupOrphanedData(in context: NSManagedObjectContext) async {
        Log.debug("Starting orphaned data cleanup", category: .coreData)
        let startTime = CFAbsoluteTimeGetCurrent()

        await removeOrphanedPendingActions(in: context)
        await removeOrphanedMessages(in: context)
        await removeOrphanedConversationParticipants(in: context)
        await removeOrphanedMessageParticipants(in: context)
        await removeStaleLabels(in: context)

        let duration = CFAbsoluteTimeGetCurrent() - startTime
        Log.debug("Completed orphaned data cleanup in \(String(format: "%.3f", duration))s", category: .coreData)
    }
}
