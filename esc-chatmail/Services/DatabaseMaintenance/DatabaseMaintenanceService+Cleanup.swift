import Foundation
import CoreData

// MARK: - Cleanup Operations

extension DatabaseMaintenanceService {

    func performCleanup() async -> Bool {
        let htmlContentHandler = HTMLContentHandler.shared
        let htmlAccountGeneration = htmlContentHandler.captureAccountGeneration()
        let context = coreDataStack.newBackgroundContext()
        let cleanupService = DataCleanupService(coreDataStack: coreDataStack)

        // Best-effort, isolated from the rest of cleanup: a purge failure must
        // not abort attachment cleanup below (which bails on the first false).
        await context.perform {
            _ = PersistentHistoryPurger.purgeHistory(in: context)
        }

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

        await Self.cleanupOrphanedHTMLFiles(
            in: context,
            htmlContentHandler: htmlContentHandler,
            expectedGeneration: htmlAccountGeneration
        )
        await AttachmentDownloader.shared.cleanupOrphanedFiles()
        return true
    }

    /// A failed ID read cannot prove that any body is orphaned. Keep the
    /// generation captured before maintenance began so old work cannot prune
    /// a replacement account's files after an asynchronous database operation.
    static func cleanupOrphanedHTMLFiles(
        in context: NSManagedObjectContext,
        htmlContentHandler: HTMLContentHandler,
        expectedGeneration: HTMLContentAccountGeneration?,
        fetchMessageIDs: @escaping @Sendable (NSManagedObjectContext) throws -> [NSDictionary] = { context in
            let request = NSFetchRequest<NSDictionary>(entityName: "Message")
            request.resultType = .dictionaryResultType
            request.propertiesToFetch = ["id"]
            return try context.fetch(request)
        }
    ) async {
        guard let expectedGeneration else { return }

        let validMessageIds: Set<String>? = await context.perform {
            do {
                let results = try fetchMessageIDs(context)
                return Set(results.compactMap { $0["id"] as? String })
            } catch {
                Log.error("Skipping orphaned HTML cleanup because message IDs could not be read", category: .coreData, error: error)
                return nil
            }
        }

        guard let validMessageIds else { return }
        htmlContentHandler.cleanupOrphanedFiles(
            validMessageIds: validMessageIds,
            expectedGeneration: expectedGeneration
        )
    }
}
