import Foundation
import CoreData

// MARK: - Cleanup Operations

extension DatabaseMaintenanceService {

    func performCleanup() async -> Bool {
        await StoreMaintenanceCoordinator.shared.runExclusivelyWhenStoreIsIdle(operationName: "database cleanup") {
            await self.performCleanupWhileStoreIsIdle()
        }
    }

    private func performCleanupWhileStoreIsIdle() async -> Bool {
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
                let deletedIDs = try Self.deleteOrphanedAttachments(in: context)
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

        // A pass whose save failed was rolled back, so the save below finds
        // nothing to commit and would report success; the outcome is the only
        // signal. A cancelled run skipped its remaining passes. Either way the
        // run is incomplete, and the orphan-file sweeps below wait for one
        // that completes.
        switch await cleanupService.runMaintenanceCleanup(in: context) {
        case .completed:
            break
        case .cancelled:
            Log.info("Database cleanup cancelled before its last maintenance pass", category: .coreData)
            return false
        case .saveFailed:
            Log.error("Database cleanup failed: a maintenance pass could not save and was rolled back", category: .coreData)
            return false
        }

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

    /// Live compose attachments have not yet been handed to a message. Hold
    /// their lease through the batch delete so a new draft cannot race the
    /// orphan predicate between resource capture and deletion.
    nonisolated static func deleteOrphanedAttachments(
        in context: NSManagedObjectContext,
        leases: ComposeAttachmentLeaseRegistry = .shared
    ) throws -> [NSManagedObjectID] {
        try leases.withProtectedResources { resources in
            let request = NSFetchRequest<NSFetchRequestResult>(entityName: "Attachment")
            request.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
                AttachmentPredicates.orphaned,
                NSPredicate(format: "id == nil OR NOT (id IN %@)", Array(resources.attachmentIDs))
            ])
            let deletion = NSBatchDeleteRequest(fetchRequest: request)
            deletion.resultType = .resultTypeObjectIDs
            let result = try context.execute(deletion) as? NSBatchDeleteResult
            return result?.result as? [NSManagedObjectID] ?? []
        }
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
