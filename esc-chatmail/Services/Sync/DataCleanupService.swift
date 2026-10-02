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

    /// How a store-wide maintenance run ended. Only `.completed` may mark the
    /// cadence or report the run as successful.
    enum MaintenanceRunOutcome: Equatable, Sendable {
        /// Every pass ran and every pass's hold saved.
        case completed
        /// The task was cancelled before the last pass ran.
        case cancelled
        /// At least one pass's hold failed to save and was rolled back. Later
        /// passes still ran (each reads its own snapshot), but the rolled-back
        /// pass's work is lost until the next due run, so the run must not
        /// count as done.
        case saveFailed
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
    /// Commits the context at the end of each cleanup-sensitive hold
    /// (`settleCleanupSensitiveHold`). Throwing rather than returning a Bool
    /// so the hold can log the underlying error with the pass that hit it.
    /// Injected so tests can fail one pass's save on demand.
    let saveCleanupHold: @Sendable (NSManagedObjectContext) async throws -> Void

    // MARK: - Initialization

    init(
        coreDataStack: CoreDataStack = .shared,
        conversationManager: ConversationManager = ConversationManager(),
        conversationMutationSerializer: ConversationRollupMutationSerializer = .shared,
        migrationFlags: MigrationFlagStore = UserDefaults.standard,
        identityAliasProvider: @escaping @Sendable (NSManagedObjectContext) async -> Set<String> = { context in
            await AliasManager.shared.getAliases(from: context)
        },
        maintenanceScheduleDefaults: UserDefaults = .standard,
        saveCleanupHold: @escaping @Sendable (NSManagedObjectContext) async throws -> Void = { context in
            try await context.perform {
                guard context.hasChanges else { return }
                try context.save()
            }
        }
    ) {
        self.coreDataStack = coreDataStack
        self.conversationManager = conversationManager
        self.conversationMutationSerializer = conversationMutationSerializer
        self.migrationFlags = migrationFlags
        self.identityAliasProvider = identityAliasProvider
        self.maintenanceScheduleDefaults = maintenanceScheduleDefaults
        self.saveCleanupHold = saveCleanupHold
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
    /// interrupted between passes, or one in which a pass's save failed,
    /// retries at the next sync.
    /// - Parameter context: The Core Data context
    func runIncrementalCleanup(in context: NSManagedObjectContext) async {
        await conversationMutationSerializer.performCleanupSensitiveMutation { [self] in
            await splitConversationsByParticipantSetIfNeeded(in: context)
            await decodeRFC2047HeaderTextIfNeeded(in: context)
            // Not checked: each flag-gated migration latches its flag only
            // after its own save succeeds, so a failure here (logged by the
            // hold) leaves it to retry at the next sync, and it has no bearing
            // on the store-wide cadence below.
            _ = await settleCleanupSensitiveHold(
                in: context,
                caller: "DataCleanupService.runIncrementalCleanup"
            )
        }

        guard IncrementalCleanupSchedule.isDue(defaults: maintenanceScheduleDefaults) else {
            Log.debug("Skipping incremental cleanup; cadence not due", category: .coreData)
            return
        }
        switch await runMaintenancePassesCooperatively(in: context) {
        case .completed:
            IncrementalCleanupSchedule.markRun(defaults: maintenanceScheduleDefaults)
        case .cancelled:
            Log.debug("Maintenance cleanup stopped between passes; will retry next sync", category: .coreData)
        case .saveFailed:
            Log.warning("Maintenance cleanup rolled back a failed pass; will retry next sync", category: .coreData)
        }
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
    /// - Returns: `.completed` only when every pass ran and saved; callers
    ///   must not report success otherwise. A failed pass is rolled back,
    ///   which leaves the context clean, so a caller's own save afterwards
    ///   cannot detect it.
    func runMaintenanceCleanup(in context: NSManagedObjectContext) async -> MaintenanceRunOutcome {
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
    /// A pass whose save fails does not stop the run: the passes are
    /// independent (each reads its own snapshot), and the rollback leaves
    /// nothing staged for the next one. The failure still decides the
    /// outcome, so the cadence stays due and the rolled-back work retries.
    ///
    /// - Returns: `.cancelled` when the task was cancelled before the last
    ///   pass ran, `.saveFailed` when any pass's hold rolled back; either way
    ///   the caller leaves the cadence unmarked and the next run retries.
    private func runMaintenancePassesCooperatively(in context: NSManagedObjectContext) async -> MaintenanceRunOutcome {
        var didFailSave = false
        for pass in maintenancePasses() {
            guard !Task.isCancelled else { return .cancelled }
            let saved = await conversationMutationSerializer.performCleanupSensitiveMutation { [self] in
                await pass.run(context)
                return await settleCleanupSensitiveHold(
                    in: context,
                    caller: "DataCleanupService.\(pass.name)"
                )
            }
            if !saved { didFailSave = true }
        }
        return didFailSave ? .saveFailed : .completed
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
    ///
    /// - Returns: false when the save failed. The rollback leaves the context
    ///   with nothing to save, so this result is the only record of the
    ///   failure: a caller's later `saveIfNeeded` succeeds trivially and must
    ///   not be read as the pass having committed.
    private func settleCleanupSensitiveHold(
        in context: NSManagedObjectContext,
        caller: String
    ) async -> Bool {
        var saved = true
        do {
            try await saveCleanupHold(context)
        } catch {
            saved = false
            Log.error("Cleanup hold save failed in \(caller); rolling back", category: .coreData, error: error)
        }
        await context.perform { [saved] in
            if !saved { context.rollback() }
            context.refreshAllObjects()
            PersonFactory.resetCache(in: context)
        }
        return saved
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
