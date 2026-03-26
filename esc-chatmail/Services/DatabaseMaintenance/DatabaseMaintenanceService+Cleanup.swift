import Foundation
import CoreData

// MARK: - Cleanup Operations

extension DatabaseMaintenanceService {

    func performCleanup() async -> Bool {
        let context = coreDataStack.newBackgroundContext()
        let cleanupService = DataCleanupService(coreDataStack: coreDataStack)

        let succeeded = await context.perform {
            do {
                // Cleanup orphaned attachments that may remain from older bugs or interrupted deletes.
                let orphanedAttachmentRequest = NSFetchRequest<NSFetchRequestResult>(entityName: "Attachment")
                orphanedAttachmentRequest.predicate = AttachmentPredicates.orphaned

                let deleteOrphaned = NSBatchDeleteRequest(fetchRequest: orphanedAttachmentRequest)
                deleteOrphaned.resultType = .resultTypeObjectIDs

                let orphanedResult = try context.execute(deleteOrphaned) as? NSBatchDeleteResult
                let deletedIDs = orphanedResult?.result as? [NSManagedObjectID] ?? []
                Log.debug("Deleted \(deletedIDs.count) orphaned attachments", category: .coreData)

                if !deletedIDs.isEmpty {
                    let changes = [NSDeletedObjectsKey: deletedIDs]
                    NSManagedObjectContext.mergeChanges(
                        fromRemoteContextSave: changes,
                        into: [self.coreDataStack.viewContext]
                    )
                }
                return true
            } catch {
                Log.error("Database cleanup failed", category: .coreData, error: error)
                return false
            }
        }

        guard succeeded else { return false }

        await cleanupService.runMaintenanceCleanup(in: context)

        guard coreDataStack.saveIfNeeded(context: context) else {
            Log.error("Database cleanup failed while saving maintenance changes", category: .coreData)
            return false
        }

        let validMessageIds: Set<String> = await context.perform {
            let request = NSFetchRequest<NSFetchRequestResult>(entityName: "Message")
            request.resultType = .dictionaryResultType
            request.propertiesToFetch = ["id"]

            guard let results = try? context.fetch(request) as? [NSDictionary] else {
                return []
            }

            return Set(results.compactMap { $0["id"] as? String })
        }

        HTMLContentHandler.shared.cleanupOrphanedFiles(validMessageIds: validMessageIds)
        await AttachmentDownloader.shared.cleanupOrphanedFiles()
        return true
    }
}
