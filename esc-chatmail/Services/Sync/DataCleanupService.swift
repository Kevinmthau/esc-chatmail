import Foundation
import CoreData
import CryptoKit

/// Handles data cleanup operations like duplicate removal and empty conversation cleanup
final class DataCleanupService: @unchecked Sendable {
    private let coreDataStack: CoreDataStack
    private let conversationManager: ConversationManager

    init(
        coreDataStack: CoreDataStack = .shared,
        conversationManager: ConversationManager = ConversationManager()
    ) {
        self.coreDataStack = coreDataStack
        self.conversationManager = conversationManager
    }

    /// Runs full cleanup including duplicate removal
    /// - Parameter context: The Core Data context
    func runFullCleanup(in context: NSManagedObjectContext) async {
        await migrateConversationsToArchiveModel(in: context)
        await removeDuplicateMessages(in: context)
        await removeDuplicateConversations(in: context)
    }

    // MARK: - Archive Model Migration

    /// Migrates existing conversations to the new archive model
    /// - Sets archivedAt for conversations that are hidden or have no inbox messages
    /// - Sets participantHash for conversations that don't have one
    func migrateConversationsToArchiveModel(in context: NSManagedObjectContext) async {
        let hasDoneMigration = UserDefaults.standard.bool(forKey: "hasDoneArchiveModelMigrationV1")
        guard !hasDoneMigration else { return }

        Log.info("Starting archive model migration...", category: .coreData)
        let startTime = CFAbsoluteTimeGetCurrent()

        await context.perform {
            let request = Conversation.fetchRequest()
            request.fetchBatchSize = 50

            guard let conversations = try? context.fetch(request) else {
                Log.warning("Failed to fetch conversations for migration", category: .coreData)
                return
            }

            var archivedCount = 0
            var participantHashCount = 0

            for conversation in conversations {
                // Set archivedAt for archived conversations
                if conversation.archivedAt == nil && (conversation.hidden || !conversation.hasInbox) {
                    conversation.archivedAt = conversation.lastMessageDate ?? Date()
                    archivedCount += 1
                }

                // Set participantHash if missing
                if conversation.participantHash == nil {
                    // Build participant hash from participants
                    let emails = conversation.participantsArray.map { normalizedEmail($0) }.sorted()
                    if !emails.isEmpty {
                        let participantKey = "p|\(emails.joined(separator: "|"))"
                        let hash = SHA256.hash(data: Data(participantKey.utf8))
                            .map { String(format: "%02x", $0) }
                            .joined()
                        conversation.participantHash = hash
                        participantHashCount += 1
                    }
                }
            }

            self.coreDataStack.saveIfNeeded(context: context)

            let duration = CFAbsoluteTimeGetCurrent() - startTime
            Log.info("Archive model migration complete in \(String(format: "%.2f", duration))s - archivedAt: \(archivedCount), participantHash: \(participantHashCount)", category: .coreData)
        }

        UserDefaults.standard.set(true, forKey: "hasDoneArchiveModelMigrationV1")
    }

    /// Runs incremental cleanup (no duplicate message check)
    /// - Parameter context: The Core Data context
    func runIncrementalCleanup(in context: NSManagedObjectContext) async {
        await removeDuplicateConversations(in: context)
        await removeEmptyConversations(in: context)
        await removeDraftMessages(in: context)
    }

    // MARK: - Duplicate Message Removal

    func removeDuplicateMessages(in context: NSManagedObjectContext) async {
        let startTime = CFAbsoluteTimeGetCurrent()

        // Step 1: Find duplicate message IDs using a lightweight dictionary fetch
        let request = NSFetchRequest<NSFetchRequestResult>(entityName: "Message")
        request.resultType = .dictionaryResultType
        request.propertiesToFetch = ["id"]
        request.returnsDistinctResults = false

        guard let results = try? context.fetch(request) as? [[String: Any]] else { return }

        // Build a map of id -> count to find duplicates
        var idCounts = [String: Int]()
        for result in results {
            if let id = result["id"] as? String {
                idCounts[id, default: 0] += 1
            }
        }

        // Get IDs that appear more than once
        let duplicateIds = idCounts.filter { $0.value > 1 }.map { $0.key }

        guard !duplicateIds.isEmpty else {
            Log.debug("No duplicate messages found", category: .coreData)
            return
        }

        // Step 2: For each duplicate ID, keep one and delete the rest
        var totalDeleted = 0

        for duplicateId in duplicateIds {
            let findRequest = NSFetchRequest<NSFetchRequestResult>(entityName: "Message")
            findRequest.predicate = NSPredicate(format: "id == %@", duplicateId)
            findRequest.sortDescriptors = [NSSortDescriptor(key: "internalDate", ascending: false)]
            findRequest.resultType = .managedObjectIDResultType

            guard let objectIDs = try? context.fetch(findRequest) as? [NSManagedObjectID],
                  objectIDs.count > 1 else { continue }

            // Keep the first (newest), delete the rest
            let idsToDelete = Array(objectIDs.dropFirst())

            let batchDeleteRequest = NSBatchDeleteRequest(objectIDs: idsToDelete)
            batchDeleteRequest.resultType = .resultTypeObjectIDs

            do {
                let deleteResult = try context.execute(batchDeleteRequest) as? NSBatchDeleteResult
                if let deletedIDs = deleteResult?.result as? [NSManagedObjectID] {
                    let changes = [NSDeletedObjectsKey: deletedIDs]
                    NSManagedObjectContext.mergeChanges(
                        fromRemoteContextSave: changes,
                        into: [coreDataStack.viewContext]
                    )
                    totalDeleted += deletedIDs.count
                }
            } catch {
                Log.error("Batch delete failed for duplicate \(duplicateId)", category: .coreData, error: error)
            }
        }

        let duration = CFAbsoluteTimeGetCurrent() - startTime
        if totalDeleted > 0 {
            Log.info("Removed \(totalDeleted) duplicate messages in \(String(format: "%.2f", duration))s", category: .coreData)
        }
    }

    // MARK: - Duplicate Conversation Removal

    func removeDuplicateConversations(in context: NSManagedObjectContext) async {
        await conversationManager.removeDuplicateConversations(in: context)
    }

    // MARK: - Empty Conversation Removal

    func removeEmptyConversations(in context: NSManagedObjectContext) async {
        let startTime = CFAbsoluteTimeGetCurrent()

        await context.perform {
            let request = NSFetchRequest<NSFetchRequestResult>(entityName: "Conversation")
            request.predicate = NSPredicate(format: "messages.@count == 0 AND participants.@count == 0")
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

    private nonisolated func removeEmptyConversationsFallback(in context: NSManagedObjectContext) {
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

    // MARK: - Draft Message Removal

    func removeDraftMessages(in context: NSManagedObjectContext) async {
        let startTime = CFAbsoluteTimeGetCurrent()

        await context.perform {
            let fetchRequest = NSFetchRequest<NSFetchRequestResult>(entityName: "Message")
            fetchRequest.predicate = NSPredicate(format: "ANY labels.id == %@", "DRAFTS")

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

    private nonisolated func removeDraftMessagesFallback(in context: NSManagedObjectContext) {
        let request = Message.fetchRequest()
        request.predicate = NSPredicate(format: "ANY labels.id == %@", "DRAFTS")
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
