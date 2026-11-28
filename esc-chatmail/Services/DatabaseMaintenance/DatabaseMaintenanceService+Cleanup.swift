import Foundation
import CoreData

// MARK: - Cleanup Operations

extension DatabaseMaintenanceService {

    func performCleanup() async -> Bool {
        await storeMaintenanceCoordinator.runExclusivelyWhenStoreIsIdle(operationName: "database cleanup") {
            await self.performCleanupWhileStoreIsIdle()
        }
    }

    private func performCleanupWhileStoreIsIdle() async -> Bool {
        // Read before `newBackgroundContext()`, whose first touch of the lazy
        // container would start the store load here, inside the maintenance
        // run and outside the bootstrap's fresh-install-then-load order. The
        // handler asked for readiness first; a reset whose reload failed since
        // then leaves the bootstrap ready and this flag false.
        guard coreDataStack.isStoreLoaded else {
            Log.info("Database cleanup skipped: the store is not loaded", category: .coreData)
            return false
        }
        let htmlContentHandler = self.htmlContentHandler()
        let htmlAccountGeneration = htmlContentHandler.captureAccountGeneration()
        let context = coreDataStack.newBackgroundContext()
        let cleanupService = makeDataCleanupService(coreDataStack)

        guard !Task.isCancelled else { return false }

        // The flag is not a witness (`CoreDataStack.requireAttachedStore(in:)`).
        // Nothing below runs against a coordinator with no store: the batch
        // delete raises there (`deleteOrphanedAttachments`), what the history
        // purge does there is not known, and the sweeps would read every file
        // as an orphan.
        guard await context.perform({ CoreDataStack.hasAttachedStore(context) }) else {
            Log.error("Database cleanup skipped: no store is attached", category: .coreData)
            return false
        }

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

        // The two file sweeps list whole directories. A run that was
        // cancelled (a background task's expiration, a sign-out's
        // quiescence) leaves them to the next one: an orphan file costs disk
        // space and nothing else.
        guard !Task.isCancelled else {
            Log.info("Database cleanup cancelled before its orphan-file sweeps", category: .coreData)
            return false
        }
        let bodySweep = await Self.cleanupOrphanedHTMLFiles(
            in: context,
            htmlContentHandler: htmlContentHandler,
            expectedGeneration: htmlAccountGeneration
        )
        guard !Task.isCancelled else {
            Log.info("Database cleanup cancelled before its attachment-file sweep", category: .coreData)
            return false
        }
        // A body sweep that stopped early (an unreadable chunk, an account
        // transition) leaves the attachment sweep its own read; the cleanup
        // is still reported as not done.
        await sweepOrphanedAttachmentFiles()
        guard bodySweep == .completed else {
            Log.info("Database cleanup's orphaned body sweep did not complete", category: .coreData)
            return false
        }
        return true
    }

    /// Live compose attachments have not yet been handed to a message. Hold
    /// their lease through the batch delete so a new draft cannot race the
    /// orphan predicate between resource capture and deletion.
    nonisolated static func deleteOrphanedAttachments(
        in context: NSManagedObjectContext,
        leases: ComposeAttachmentLeaseRegistry = .shared
    ) throws -> [NSManagedObjectID] {
        // A batch delete on a coordinator with no store raises
        // NSInternalInconsistencyException ("has no persistent stores"),
        // which Swift cannot catch: measured on the iOS 27.0 simulator
        // (AttachedStoreGuardTests' revert-check), it crashed the process.
        try CoreDataStack.requireAttachedStore(in: context)
        return try leases.withProtectedResources { resources in
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

    /// The daily sweep of `Messages` for bodies no stored row names. It runs off the main
    /// actor (`nonisolated`), awaited in the maintenance run's own task, never a detached one:
    /// the run's cancellation (a background task's expiration, a sign-out's quiescence) reaches
    /// it between chunks only through that task, and the run must not end while it unlinks,
    /// or a sync could write a body before its row is saved and see it removed
    /// (`StoreMaintenanceCoordinatorTests`). Until 2026-11-28 it fetched every message ID into
    /// one set and then swept the whole directory on the main actor under the HTML boundary's
    /// lock (architecture review 2026-11, attachments-storage-disk#6).
    ///
    /// The store is asked a chunk at a time (`HTMLContentHandler.cleanupOrphanedFiles`), each
    /// time behind `CoreDataStack.requireAttachedStore(in:)`, which stays outside the
    /// injectable fetch: on a coordinator with no store the fetch answers [] and every body
    /// would be an orphan. A failed read removes nothing and stops the sweep. A nil generation (the
    /// boundary was closed when maintenance began) sweeps nothing, and the generation it was
    /// given keeps old work from pruning a replacement account's files.
    nonisolated static func cleanupOrphanedHTMLFiles(
        in context: NSManagedObjectContext,
        htmlContentHandler: HTMLContentHandler,
        expectedGeneration: HTMLContentAccountGeneration?,
        chunkSize: Int = 100,
        fetchLiveMessageIDs: @escaping @Sendable (Set<String>, NSManagedObjectContext) throws -> Set<String> = { ids, context in
            try DeletedRowFileReclamation.liveMessageIDs(among: ids, in: context)
        }
    ) async -> OrphanedBodySweepOutcome {
        guard let expectedGeneration else { return .accountChanged }
        return htmlContentHandler.cleanupOrphanedFiles(
            expectedGeneration: expectedGeneration,
            chunkSize: chunkSize,
            liveMessageIDs: { ids in
                try context.performAndWait {
                    try CoreDataStack.requireAttachedStore(in: context)
                    return try fetchLiveMessageIDs(ids, context)
                }
            }
        )
    }
}
