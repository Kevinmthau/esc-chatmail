import Foundation
import CoreData
import os

extension Notification.Name {
    /// Posted when one of `DataCleanupService`'s cleanup runs ends
    /// (`runFullCleanup`, `runIncrementalCleanup`, `runMaintenanceCleanup`,
    /// which `runStoreMaintenanceIfDue` ends in), whatever came of it, after
    /// the run's own saves.
    ///
    /// Those runs are the only writers of two things that are read to decide
    /// who a reply goes to: the contact links (adopted in the first step of
    /// the two sync cleanups) and a stored conversation's participant rows
    /// (the hash repair and the merges). A chat left open asks again when it
    /// hears this (`ChatViewModel`). `.syncCompleted` alone was not enough:
    /// it is posted only by a sync run that succeeded. The daily database
    /// cleanup task (`DatabaseMaintenanceService.performCleanup`) runs the
    /// maintenance passes outside any sync, on the Mac while the app is open,
    /// the 6-hour maintenance runs after the sync that found it due has
    /// posted, and the first initial sync runs the full cleanup before work
    /// that can then fail.
    ///
    /// It can come from any thread.
    static let conversationCleanupFinished = Notification.Name("com.esc.inboxchat.conversationCleanupFinished")
}

/// Handles data cleanup operations like duplicate removal and empty conversation cleanup.
///
/// The service is split across multiple files for organization:
/// - `DataCleanupService.swift` - Core structure and orchestration
/// - `DataCleanupService+Migration.swift` - Archive model migration
/// - `DataCleanupService+ContactUnification.swift` - One chat per contact when their linked addresses change
/// - `DataCleanupService+DuplicateRemoval.swift` - Duplicate conversation removal
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

    /// What became of a request for the 6-hour store maintenance
    /// (`runStoreMaintenanceIfDue`).
    enum DueStoreMaintenanceOutcome: Equatable, Sendable {
        /// The cadence was not due. Nothing ran.
        case notDue
        /// The cadence was due and the passes did not start: another
        /// maintenance run was active, the task was cancelled while it
        /// waited, or an account transition began. The cadence stays due.
        case notAdmitted
        /// The passes ran, and ended this way. Only `.completed` marked the
        /// cadence.
        case finished(MaintenanceRunOutcome)
    }

    /// Which conversations `fixAndMergeIncorrectParticipantHashes` reads.
    enum ParticipantHashRepairScope: Sendable {
        /// Every active conversation: the store-wide maintenance run.
        case activeConversations
        /// The conversations, active or archived, that have a participant row
        /// for one of these normalized addresses: a change in the addresses a
        /// contact card links, which touches nobody else's conversations.
        case conversationsNaming(Set<String>)

        /// Whether a conversation a pending send or a saved reply draft
        /// anchors takes its correct hash in place, with nothing else about
        /// it written. True for a change in linked addresses: the router is
        /// already hashing with the new map, so an anchor left on its old
        /// hash loses its mail to a second chat for as long as it is anchored.
        /// False for maintenance, which repairs hashes that were stored wrong
        /// under a map that did not change, and leaves an anchor untouched as
        /// it always has.
        var givesAnchoredConversationsTheirHash: Bool {
            switch self {
            case .activeConversations: false
            case .conversationsNaming: true
            }
        }
    }

    /// How `fixAndMergeIncorrectParticipantHashes` ended.
    enum ParticipantHashRepairOutcome: Equatable, Sendable {
        /// Every conversation in scope carries its correct hash, and those
        /// that came to share one were merged.
        case completed
        /// The pass could not finish a conversation in scope because a
        /// pending send, a saved reply draft or a deferred chat-preview retry
        /// anchors to it: its rows were not folded, it was not merged with the
        /// conversation that came to share its hash, or (a chat-preview retry,
        /// or any anchor in maintenance) it kept a wrong hash. The rest of the
        /// scope was repaired and saved; the pass is due again once the anchor
        /// is released.
        case blockedByProtectedConversation
        /// Nothing was committed: the account's aliases are not known yet, or
        /// a fetch or the save failed.
        case incomplete
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
    /// The linked-address map identity hashes with, for the same reason as the
    /// aliases above: every pass that recomputes a participant hash reads
    /// `snapshot()` once and hashes with what the router is using. Injected so
    /// tests build a store of their own; the shared one holds nothing under
    /// unit tests.
    let contactLinkStore: ContactLinkedAddressStore
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
    /// Tells whoever reads what a cleanup run writes that one has ended
    /// (`.conversationCleanupFinished`). A closure, so a test can count the
    /// calls without listening on the default center, which every other
    /// suite's cleanup posts to.
    let announceCleanupFinished: @Sendable () -> Void

    // MARK: - Initialization

    init(
        coreDataStack: CoreDataStack = .shared,
        conversationManager: ConversationManager = ConversationManager(),
        conversationMutationSerializer: ConversationRollupMutationSerializer = .shared,
        migrationFlags: MigrationFlagStore = UserDefaults.standard,
        identityAliasProvider: @escaping @Sendable (NSManagedObjectContext) async -> Set<String> = { context in
            await AliasManager.shared.getAliases(from: context)
        },
        contactLinkStore: ContactLinkedAddressStore = .shared,
        maintenanceScheduleDefaults: UserDefaults = .standard,
        saveCleanupHold: @escaping @Sendable (NSManagedObjectContext) async throws -> Void = { context in
            try await context.perform {
                guard context.hasChanges else { return }
                try context.save()
            }
        },
        announceCleanupFinished: @escaping @Sendable () -> Void = {
            NotificationCenter.default.post(name: .conversationCleanupFinished, object: nil)
        }
    ) {
        self.coreDataStack = coreDataStack
        self.conversationManager = conversationManager
        self.conversationMutationSerializer = conversationMutationSerializer
        self.migrationFlags = migrationFlags
        self.identityAliasProvider = identityAliasProvider
        self.contactLinkStore = contactLinkStore
        self.maintenanceScheduleDefaults = maintenanceScheduleDefaults
        self.saveCleanupHold = saveCleanupHold
        self.announceCleanupFinished = announceCleanupFinished
    }

    // MARK: - Orchestration

    /// Runs full cleanup, including duplicate-conversation removal.
    /// - Parameter context: The Core Data context
    func runFullCleanup(in context: NSManagedObjectContext) async {
        await conversationMutationSerializer.performCleanupSensitiveMutation { [self] in
            await migrateConversationsToArchiveModel(in: context)
            // Before every pass that hashes: it adopts the linked addresses
            // the rest of this hold hashes with.
            await unifyConversationsByContactIfNeeded(in: context)
            await splitConversationsByParticipantSetIfNeeded(in: context)
            await decodeRFC2047HeaderTextIfNeeded(in: context)
            await repairAddressShapedPersonDisplayNamesIfNeeded(in: context)
            await peelQuoteWrappedDisplayNamesIfNeeded(in: context)
            await removeDuplicateConversations(in: context)
            await mergeActiveConversationDuplicates(in: context)
            _ = await context.performSaveIfNeeded(
                caller: "DataCleanupService.runFullCleanup"
            )
        }
        announceCleanupFinished()
    }

    /// Runs the cleanup every incremental sync makes inside its own run: the
    /// flag-gated migrations, in one cleanup-sensitive hold. In steady state
    /// each is a no-op, so the hold costs a save of nothing.
    ///
    /// The store-wide maintenance passes are not run here. They ran here,
    /// when their 6-hour cadence was due, before the sync posted
    /// `.syncCompleted`: the sync that met the cadence held its run, and
    /// everything waiting on its completion, for all of them. They are a run
    /// of their own now, started once the sync's run has ended
    /// (`runStoreMaintenanceIfDue`).
    /// - Parameter context: The Core Data context
    func runIncrementalCleanup(in context: NSManagedObjectContext) async {
        // After the hold's save: it adopts contact links and can rewrite
        // participant rows.
        defer { announceCleanupFinished() }
        await conversationMutationSerializer.performCleanupSensitiveMutation { [self] in
            // First: it adopts the linked addresses every later pass of this
            // run hashes with. In steady state it reads no conversation.
            await unifyConversationsByContactIfNeeded(in: context)
            await splitConversationsByParticipantSetIfNeeded(in: context)
            await decodeRFC2047HeaderTextIfNeeded(in: context)
            // After the RFC 2047 pass, which decodes the senderName values
            // this one reads.
            await repairAddressShapedPersonDisplayNamesIfNeeded(in: context)
            await peelQuoteWrappedDisplayNamesIfNeeded(in: context)
            // Not checked: each flag-gated migration latches its flag only
            // after its own save succeeds, so a failure here (logged by the
            // hold) leaves it to retry at the next sync.
            _ = await settleCleanupSensitiveHold(
                in: context,
                caller: "DataCleanupService.runIncrementalCleanup"
            )
        }
    }

    /// Runs incremental cleanup in a dedicated background context.
    /// This avoids resetting or batch-deleting the active sync transaction context.
    func runIncrementalCleanup() async {
        let context = coreDataStack.newBackgroundContext()
        await runIncrementalCleanup(in: context)
    }

    /// Runs the store-wide maintenance passes if their 6-hour cadence is due,
    /// as an exclusive maintenance run of its own.
    ///
    /// Call it after a sync's run has ended, never from inside one: it takes
    /// the exclusive run, and a holder of a run or a lease that waited for
    /// that would never be released. It waits behind a run that is active
    /// and gives up if another maintenance run is, or if an account
    /// transition has started; the cadence then stays due for the next sync.
    /// Cancelling the calling task, or an account transition's quiescence,
    /// stops the run between two passes.
    @discardableResult
    func runStoreMaintenanceIfDue(
        exclusiveRunner: StoreMaintenanceCoordinator = .shared
    ) async -> DueStoreMaintenanceOutcome {
        // Asked here as well as inside the run, so that the sync that finds
        // nothing due, which is nearly every sync, takes no run at all.
        guard IncrementalCleanupSchedule.isDue(defaults: maintenanceScheduleDefaults) else {
            return .notDue
        }
        let outcome = OSAllocatedUnfairLock<DueStoreMaintenanceOutcome>(initialState: .notAdmitted)
        _ = await exclusiveRunner.runExclusivelyWhenStoreIsIdle(operationName: "store maintenance") { [self] in
            let result = await runStoreMaintenanceIfDue(in: coreDataStack.newBackgroundContext())
            outcome.withLock { $0 = result }
            return result == .finished(.completed) || result == .notDue
        }
        return outcome.withLock { $0 }
    }

    /// The passes and their cadence, for a caller that already owns the
    /// store: `runStoreMaintenanceIfDue(exclusiveRunner:)` inside its
    /// exclusive run, and tests.
    ///
    /// Each pass takes the cleanup-sensitive gate on its own
    /// (`runMaintenancePassesCooperatively`) rather than around the whole
    /// run: optimistic-send creation queues on the same gate, and one hold
    /// spanning every store-wide pass kept a reply's bubble from appearing
    /// until all of them finished. The cadence is marked only after the last
    /// pass, so a run interrupted between passes, or one in which a pass's
    /// save failed, is due again at the next sync.
    func runStoreMaintenanceIfDue(in context: NSManagedObjectContext) async -> DueStoreMaintenanceOutcome {
        guard IncrementalCleanupSchedule.isDue(defaults: maintenanceScheduleDefaults) else {
            Log.debug("Skipping store maintenance; cadence not due", category: .coreData)
            return .notDue
        }
        // Announces when it ends, whatever came of it.
        let outcome = await runMaintenanceCleanup(in: context)
        switch outcome {
        case .completed:
            IncrementalCleanupSchedule.markRun(defaults: maintenanceScheduleDefaults)
        case .cancelled:
            Log.debug("Store maintenance stopped between passes; will retry after the next sync", category: .coreData)
        case .saveFailed:
            Log.warning("Store maintenance rolled back a failed pass; will retry after the next sync", category: .coreData)
        }
        return .finished(outcome)
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
        // Also for a run that was cancelled or lost a pass's save: the passes
        // before it saved theirs. This run belongs to no sync, so nothing
        // else says it happened.
        defer { announceCleanupFinished() }
        return await runMaintenancePassesCooperatively(in: context)
    }

    /// The store-wide maintenance passes, in run order. Every destructive pass
    /// reads its own protection snapshot (`pendingSendConversationIDs`,
    /// PendingAction references) inside its own `context.perform`, so none
    /// relies on a snapshot an earlier pass took — which is what lets the gate
    /// be released between them.
    private func maintenancePasses() -> [(name: String, run: @Sendable (NSManagedObjectContext) async -> Void)] {
        [
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

    /// Conversations a chat-preview pass's deferred retry still has to visit.
    /// Passes that move rows to a different participant hash skip them like
    /// pending-send anchors; see `ChatPreviewRepair.DeferredRetryAnchors`.
    /// Call inside `context.perform` under the cleanup-sensitive gate, and
    /// fail closed if it throws.
    func chatPreviewRetryAnchors(
        in context: NSManagedObjectContext
    ) throws -> ChatPreviewRepair.DeferredRetryAnchors {
        try ChatPreviewRepair.DeferredRetryAnchors.load(
            encodedCheckpoints: ConversationLaunchRepairCoordinator.chatPreviewRepairCheckpointKeys.map {
                migrationFlags.string(forKey: $0)
            },
            in: context
        )
    }
}
