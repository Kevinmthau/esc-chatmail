import Foundation
import CoreData

// MARK: - Duplicate Removal

extension DataCleanupService {

    /// Removes duplicate messages by keeping the newest version of each message ID.
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

    /// Removes duplicate conversations by delegating to ConversationManager.
    func removeDuplicateConversations(in context: NSManagedObjectContext) async {
        await conversationManager.removeDuplicateConversations(in: context)
    }

    /// Merges active conversation duplicates by delegating to ConversationManager.
    func mergeActiveConversationDuplicates(in context: NSManagedObjectContext) async {
        await conversationManager.mergeActiveConversationDuplicates(in: context)
    }
}
