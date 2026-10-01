import Foundation
import CoreData

/// Handles data cleanup operations like duplicate removal and empty conversation cleanup.
///
/// The service is split across multiple files for organization:
/// - `DataCleanupService.swift` - Core structure and orchestration
/// - `DataCleanupService+Migration.swift` - Archive model migration
/// - `DataCleanupService+DuplicateRemoval.swift` - Duplicate message/conversation removal
/// - `DataCleanupService+EntityCleanup.swift` - Empty entity and draft cleanup
struct DataCleanupService: Sendable {

    enum IncrementalCleanupSchedule {
        static let lastRunTimeKey = "dataCleanupService.lastIncrementalCleanupAt"
        static let interval: TimeInterval = 6 * 60 * 60

        static func isDue(
            now: Date = Date(),
            defaults: UserDefaults = .standard
        ) -> Bool {
            let lastRun = defaults.double(forKey: lastRunTimeKey)
            guard lastRun > 0 else { return true }
            return now.timeIntervalSince1970 - lastRun >= interval
        }

        static func markRun(
            now: Date = Date(),
            defaults: UserDefaults = .standard
        ) {
            defaults.set(now.timeIntervalSince1970, forKey: lastRunTimeKey)
        }
    }

    // MARK: - Properties

    let coreDataStack: CoreDataStack
    let conversationManager: ConversationManager
    let conversationMutationSerializer: ConversationRollupMutationSerializer
    // Both conformers are thread-safe (UserDefaults; the locked test store), but
    // the protocol itself cannot require Sendable without breaking UserDefaults.
    nonisolated(unsafe) let migrationFlags: MigrationFlagStore
    /// Alias source for participant-identity recomputation. Must match what the
    /// sync router excludes (AliasManager), or repair passes rewrite hashes with
    /// a different self-exclusion set than routing uses and chats flip-flop.
    /// Injected so tests avoid the process-global AliasManager/Contacts path.
    let identityAliasProvider: @Sendable (NSManagedObjectContext) async -> Set<String>
    /// Backing store for `IncrementalCleanupSchedule`, injected so tests can
    /// drive the 6-hour cadence without touching `UserDefaults.standard`.
    /// UserDefaults is thread-safe; `nonisolated(unsafe)` for the same reason
    /// as `migrationFlags` above.
    nonisolated(unsafe) let maintenanceScheduleDefaults: UserDefaults

    // MARK: - Initialization

    init(
        coreDataStack: CoreDataStack = .shared,
        conversationManager: ConversationManager = ConversationManager(),
        conversationMutationSerializer: ConversationRollupMutationSerializer = .shared,
        migrationFlags: MigrationFlagStore = UserDefaults.standard,
        identityAliasProvider: @escaping @Sendable (NSManagedObjectContext) async -> Set<String> = { context in
            await AliasManager.shared.getAliases(from: context)
        },
        maintenanceScheduleDefaults: UserDefaults = .standard
    ) {
        self.coreDataStack = coreDataStack
        self.conversationManager = conversationManager
        self.conversationMutationSerializer = conversationMutationSerializer
        self.migrationFlags = migrationFlags
        self.identityAliasProvider = identityAliasProvider
        self.maintenanceScheduleDefaults = maintenanceScheduleDefaults
    }

    // MARK: - Orchestration

    /// Runs full cleanup including duplicate removal.
    /// - Parameter context: The Core Data context
    func runFullCleanup(in context: NSManagedObjectContext) async {
        await conversationMutationSerializer.performCleanupSensitiveMutation { [self] in
            await migrateConversationsToArchiveModel(in: context)
            await splitConversationsByParticipantSetIfNeeded(in: context)
            await decodeRFC2047HeaderTextIfNeeded(in: context)
            await removeDuplicateMessages(in: context)
            await removeDuplicateConversations(in: context)
            await mergeActiveConversationDuplicates(in: context)
            _ = await context.performSaveIfNeeded(
                caller: "DataCleanupService.runFullCleanup"
            )
        }
    }

    /// Runs incremental cleanup (no duplicate message check).
    ///
    /// The flag-gated migrations share one cleanup-sensitive hold; in steady
    /// state both are no-ops, so that hold costs a save of nothing. The 6-hour
    /// store-wide maintenance then takes the gate once per pass
    /// (`runMaintenancePassesCooperatively`) rather than around the whole run:
    /// optimistic-send creation queues on the same gate, and one hold spanning
    /// every store-wide pass kept a reply's bubble from appearing until all of
    /// them finished. The cadence is marked only after the last pass, so a run
    /// interrupted between passes retries at the next sync.
    /// - Parameter context: The Core Data context
    func runIncrementalCleanup(in context: NSManagedObjectContext) async {
        await conversationMutationSerializer.performCleanupSensitiveMutation { [self] in
            await splitConversationsByParticipantSetIfNeeded(in: context)
            await decodeRFC2047HeaderTextIfNeeded(in: context)
            await settleCleanupSensitiveHold(
                in: context,
                caller: "DataCleanupService.runIncrementalCleanup"
            )
        }

        guard IncrementalCleanupSchedule.isDue(defaults: maintenanceScheduleDefaults) else {
            Log.debug("Skipping incremental cleanup; cadence not due", category: .coreData)
            return
        }
        guard await runMaintenancePassesCooperatively(in: context) else {
            Log.debug("Maintenance cleanup stopped between passes; will retry next sync", category: .coreData)
            return
        }
        IncrementalCleanupSchedule.markRun(defaults: maintenanceScheduleDefaults)
    }

    /// Runs incremental cleanup in a dedicated background context.
    /// This avoids resetting or batch-deleting the active sync transaction context.
    func runIncrementalCleanup() async {
        let context = coreDataStack.newBackgroundContext()
        await runIncrementalCleanup(in: context)
    }

    /// Runs the heavier store-wide maintenance tasks.
    /// Use this for periodic maintenance or one-shot repair passes, not every sync.
    /// Each pass takes the cleanup-sensitive gate on its own; see
    /// `runMaintenancePassesCooperatively`.
    func runMaintenanceCleanup(in context: NSManagedObjectContext) async {
        await runMaintenancePassesCooperatively(in: context)
    }

    /// The store-wide maintenance passes, in run order. Every destructive pass
    /// reads its own protection snapshot (`pendingSendConversationIDs`,
    /// PendingAction references) inside its own `context.perform`, so none
    /// relies on a snapshot an earlier pass took — which is what lets the gate
    /// be released between them.
    private func maintenancePasses() -> [(name: String, run: @Sendable (NSManagedObjectContext) async -> Void)] {
        [
            ("removeDuplicateMessages", { await removeDuplicateMessages(in: $0) }),
            ("removeDuplicateConversations", { await removeDuplicateConversations(in: $0) }),
            ("mergeActiveConversationDuplicates", { await mergeActiveConversationDuplicates(in: $0) }),
            ("fixAndMergeIncorrectParticipantHashes", { await fixAndMergeIncorrectParticipantHashes(in: $0) }),
            ("removeEmptyConversations", { await removeEmptyConversations(in: $0) }),
            ("removeDraftMessages", { await removeDraftMessages(in: $0) }),
            ("cleanupOrphanedData", { await cleanupOrphanedData(in: $0) }),
            // Run last: the orphan sweeps above delete participation rows, and
            // merging is cheaper once those are gone.
            ("mergeDuplicatePersons", { await mergeDuplicatePersons(in: $0) }),
            ("mergeDuplicateLabels", { await mergeDuplicateLabels(in: $0) })
        ]
    }

    /// Runs each maintenance pass in its own cleanup-sensitive hold, so an
    /// optimistic send queued behind maintenance waits for at most one pass.
    ///
    /// Releasing the gate between passes keeps the optimistic graph + mutation
    /// record atomic with respect to every cleanup snapshot only because no
    /// pass carries unsaved state across a release: each hold ends in
    /// `settleCleanupSensitiveHold`, which saves or rolls back. A reply that
    /// anchors to a conversation between two passes has committed its
    /// `OutboundSendMutationRecord` (or `ChatReplyDraft`) before the next
    /// pass's protection fetch, so merge, dedup, and empty-shell passes still
    /// exclude it.
    ///
    /// - Returns: false when the task was cancelled before the last pass ran,
    ///   so the caller leaves the cadence unmarked and the next run retries.
    @discardableResult
    private func runMaintenancePassesCooperatively(in context: NSManagedObjectContext) async -> Bool {
        for pass in maintenancePasses() {
            guard !Task.isCancelled else { return false }
            await conversationMutationSerializer.performCleanupSensitiveMutation { [self] in
                await pass.run(context)
                await settleCleanupSensitiveHold(
                    in: context,
                    caller: "DataCleanupService.\(pass.name)"
                )
            }
        }
        return true
    }

    /// Ends a cleanup-sensitive hold with nothing pending. A failed save rolls
    /// back rather than leaving staged deletions for a later hold to commit:
    /// by then a reply may have anchored to a conversation those deletions
    /// remove. The refresh drops cached row state because other gated writers
    /// (optimistic sends, draft saves, preview-repair batches) may commit
    /// before the next hold, and a registered object keeps its stale values
    /// when a later fetch returns its row again. The context's `PersonFactory`
    /// cache is dropped too: its hit check (same context, not deleted) cannot
    /// see a row another gated writer deleted between holds, so a refreshed
    /// cached `Person` would pass it and then fail to fulfill when faulted.
    private func settleCleanupSensitiveHold(
        in context: NSManagedObjectContext,
        caller: String
    ) async {
        let saved = await context.performSaveIfNeeded(caller: caller)
        await context.perform {
            if !saved { context.rollback() }
            context.refreshAllObjects()
            PersonFactory.resetCache(in: context)
        }
    }

    /// Pending sends and saved reply drafts own their conversation anchors.
    /// Callers deliberately fail closed if either reference fetch throws.
    func pendingSendConversationIDs(
        in context: NSManagedObjectContext,
        sendRecords: [OutboundSendMutationRecord]? = nil
    ) throws -> Set<UUID> {
        let sends = try sendRecords ?? context.fetch(OutboundSendMutationRecord.fetchRequest())
        let draftRequest = NSFetchRequest<ChatReplyDraft>(entityName: "ChatReplyDraft")
        return Set(sends.compactMap(\.conversationId))
            .union(try context.fetch(draftRequest).map(\.conversationId))
    }
}
