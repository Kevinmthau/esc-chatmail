import Foundation
import CoreData
import Combine

/// Owns the once-per-launch conversation-store maintenance passes that used
/// to live in `ConversationListViewModel`: the V6 display-name refresh, the
/// per-launch list-title repair, and the missing-preview repair (including
/// the stranded message-less shell sweep). Extracted so the passes stop dragging the sync engine and the
/// conversation manager into the list view model, and so tests can drive
/// them with an injectable sync-idle wait and notification center instead
/// of the shared `SyncEngine`.
///
/// The `.syncCompleted` re-arm subscribes in `init` — not in a `start()`
/// hook — because a sync run that finishes before the list first appears
/// must still re-arm the repair.
@MainActor
final class ConversationLaunchRepairCoordinator {
    /// Deliberately still V6: healing list titles stored under an older
    /// `ParsedListId` heuristic is owned by the per-launch
    /// `repairListConversationTitles` pass, so heuristic improvements must
    /// NOT ship with a bump here — a bump re-derives every conversation's
    /// name on every device for a list-only fix.
    static let conversationNameRefreshMigrationKey = "hasRefreshedConversationNamesV6"
    /// Completion marker only — the preview repair re-runs every launch and no
    /// longer skips when this flag is already set.
    static let conversationPreviewRepairMigrationKey = "hasRepairedMissingConversationPreviewsV2"
    private static let repairMissingConversationPreviewsTaskKey = "repairMissingConversationPreviews"

    private let storage: StorageDependencies
    private let conversationManager: ConversationManager
    private let syncWaiter: any ForegroundSyncPerforming
    private let notificationCenter: NotificationCenter
    private let conversationMutationSerializer: ConversationRollupMutationSerializer
    private let accountWorkCoordinator: SyncRunCoordinator
    private let htmlContentHandler: HTMLContentHandler
    private let repairTaskPriority: TaskPriority?
    private var isChatPreviewRepairRunning = false
    private var isRichContentVerdictBackfillRunning = false
    private let taskManager = ViewModelTaskManager()
    private var cancellables = Set<AnyCancellable>()

    private var isConversationPreviewRepairRunning = false
    private var hasCompletedConversationPreviewRepair = false
    private var hasObservedSyncCompletionThisLaunch = false

    private var isListConversationTitleRepairRunning = false
    private var hasCompletedListConversationTitleRepair = false

    /// - Parameters:
    ///   - storage: Supplies the view context (store-existence checks),
    ///     background contexts, saves, and the migration flag store.
    ///   - conversationManager: Performs the display-name refresh, the
    ///     message-less shell sweep, and the preview repair batches.
    ///   - syncWaiter: Awaited before the preview repair sweeps, so the sweep
    ///     never races a sync run mid-save. Production passes the
    ///     `SyncEngine`; tests inject a controllable waiter.
    ///   - notificationCenter: Source of `.syncCompleted` for the repair
    ///     re-arm. Production passes `.default`.
    ///   - repairTaskPriority: Priority of the three store sweeps that take it
    ///     directly (list titles, missing previews, persisted chat previews).
    ///     Production keeps `.background` so those never compete with the UI.
    ///     The rich-content verdict backfill does not run at this value: it
    ///     runs at `.utility` whenever this is non-nil, because its leased,
    ///     CPU-bound batches block sign-out and must not sit unscheduled
    ///     (`richContentVerdictBackfillPriority`), and inherits the caller's
    ///     priority when this is nil.
    ///     Tests pass `nil` to inherit the test's priority: on a loaded CI VM
    ///     `.background` jobs sat unscheduled for over a minute, and neither
    ///     polling nor joining the worker task reliably lifts jobs it has
    ///     already queued, so suites that assert on repair results timed out.
    init(
        storage: StorageDependencies,
        conversationManager: ConversationManager,
        syncWaiter: any ForegroundSyncPerforming,
        notificationCenter: NotificationCenter = .default,
        conversationMutationSerializer: ConversationRollupMutationSerializer = .shared,
        accountWorkCoordinator: SyncRunCoordinator = .shared,
        htmlContentHandler: HTMLContentHandler = .shared,
        repairTaskPriority: TaskPriority? = .background
    ) {
        self.storage = storage
        self.conversationManager = conversationManager
        self.syncWaiter = syncWaiter
        self.notificationCenter = notificationCenter
        self.repairTaskPriority = repairTaskPriority
        self.conversationMutationSerializer = conversationMutationSerializer
        self.accountWorkCoordinator = accountWorkCoordinator
        self.htmlContentHandler = htmlContentHandler
        bindSyncCompletionRepairRearm()
    }

    /// Runs the launch passes. Called from the list's `onAppear`; each pass
    /// owns its own per-launch guard, so repeat calls are cheap no-ops.
    func runLaunchRepairsIfNeeded() {
        refreshConversationNames()
        repairListConversationTitles()
        repairMissingConversationPreviews()
        repairPersistedChatPreviews()
        backfillRichContentVerdicts()
    }

    /// Cancels any in-flight pass. An incomplete repair clears its running
    /// guard on exit, so a later `runLaunchRepairsIfNeeded()` can re-run it.
    func cancel() {
        taskManager.cancelAll()
    }

    /// Re-arms the launch preview repair when a sync run finishes before the
    /// repair has completed: the launch pass can legitimately drain an empty
    /// store before the first sync registers (fresh install), so the first
    /// completed sync gets a fresh sweep. Once the repair completes it stays
    /// done for the launch — incremental syncs post this notification on every
    /// run, and re-sweeping each time would repeat the archive/repair fetches
    /// forever; per-page rollups already keep synced pages presentable.
    private func bindSyncCompletionRepairRearm() {
        notificationCenter.publisher(for: .syncCompleted)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.hasObservedSyncCompletionThisLaunch = true
                self.repairMissingConversationPreviews()
                self.repairPersistedChatPreviews()
                self.backfillRichContentVerdicts()
            }
            .store(in: &cancellables)
    }

    nonisolated static let chatPreviewRepairMigrationKey = "chatPreviewRepair." + CacheVersioning.chatPreviewDerivationVersion
    nonisolated static let chatPreviewRepairCheckpointKey = chatPreviewRepairMigrationKey + ".checkpoint"
    /// Not tied to the derivation version: the backfill stores what the bubble
    /// already showed, so a derivation change re-runs the re-derivation pass
    /// (which owns received HTML rows) rather than this one.
    nonisolated static let blankChatPreviewBackfillMigrationKey = "chatPreviewBlankBackfill.v1"
    nonisolated static let blankChatPreviewBackfillCheckpointKey = blankChatPreviewBackfillMigrationKey + ".checkpoint"
    /// Every pass's checkpoint. Conversation maintenance reads their deferred
    /// lists (`ChatPreviewRepair.DeferredRetryAnchors`) so it does not move
    /// rows a deferred retry still has to find; hence `nonisolated` on these
    /// keys, since that maintenance runs off the main actor.
    nonisolated static let chatPreviewRepairCheckpointKeys = [
        chatPreviewRepairCheckpointKey,
        blankChatPreviewBackfillCheckpointKey
    ]
    private static let chatPreviewRepairTaskKey = "repairPersistedChatPreviews"
    /// Rows per cleanup-sensitive hold. Each re-derivation row reads an HTML
    /// file and runs the preview derivation while the gate is held, and an
    /// optimistic send queued behind that hold waits for the whole batch at
    /// this pass's background priority (the gate's continuation does not
    /// escalate it). 100-row batches could hold it for seconds on a large,
    /// throttled store; the per-batch lease, sync-idle check, and save are
    /// cheap next to the derivation. Unmeasured: tune with a trace if needed.
    static let chatPreviewRepairBatchSize = 25

    /// One entry per persisted-preview pass, run in order under a single
    /// account-work request. Each pass owns its own completion flag and cursor.
    private struct ChatPreviewPass {
        let repair: ChatPreviewRepair
        let migrationKey: String
        let checkpointKey: String
    }

    private enum ChatPreviewPassOutcome {
        /// The pass drained with nothing deferred and latched its flag.
        case completed
        /// The pass stopped early (deferred rows, a failed save). Later passes
        /// still run; this one retries on the next launch or sync completion.
        case incomplete
        /// Cancellation or an account transition. No later pass may run.
        case stopped
    }

    private func chatPreviewPasses() -> [ChatPreviewPass] {
        [
            ChatPreviewPass(
                repair: ChatPreviewRepair(htmlContentHandler: htmlContentHandler, pass: .receivedHTMLRederivation),
                migrationKey: Self.chatPreviewRepairMigrationKey,
                checkpointKey: Self.chatPreviewRepairCheckpointKey
            ),
            ChatPreviewPass(
                repair: ChatPreviewRepair(htmlContentHandler: htmlContentHandler, pass: .blankPreviewBackfill),
                migrationKey: Self.blankChatPreviewBackfillMigrationKey,
                checkpointKey: Self.blankChatPreviewBackfillCheckpointKey
            )
        ]
    }

#if DEBUG
    func waitForChatPreviewRepairCompletion() async {
        await taskManager.waitForCompletion(of: Self.chatPreviewRepairTaskKey)
    }
#endif

    /// Checkpoint after each saved batch so cancellation or process exit can
    /// resume without re-reading every earlier HTML file. No model migration.
    /// A pass that stops early does not block the next one: a retained failed
    /// send defers its conversation indefinitely, and the backfill must not
    /// wait on it. While such a send is retained, the pass's main scan is
    /// already complete and each sync-completion re-run only re-checks the
    /// deferred conversations (`ChatPreviewRepair.Checkpoint`), so it no
    /// longer re-derives the mailbox under the gate optimistic sends wait on.
    func repairPersistedChatPreviews() {
        let pendingPasses = chatPreviewPasses().filter {
            !storage.migrationFlags.bool(forKey: $0.migrationKey)
        }
        guard !isChatPreviewRepairRunning, !pendingPasses.isEmpty else { return }
        isChatPreviewRepairRunning = true
        taskManager.run(Self.chatPreviewRepairTaskKey, priority: repairTaskPriority) { [weak self] in
            guard let self else { return }
            defer { isChatPreviewRepairRunning = false }
            guard let request = await accountWorkCoordinator.makeAccountWorkRequest() else { return }
            for pass in pendingPasses {
                let outcome = await runChatPreviewPass(pass, request: request)
                if outcome == .stopped { return }
            }
        }
    }

    private func runChatPreviewPass(
        _ pass: ChatPreviewPass,
        request: AccountWorkRequest
    ) async -> ChatPreviewPassOutcome {
        var checkpoint = ChatPreviewRepair.Checkpoint.decode(
            storage.migrationFlags.string(forKey: pass.checkpointKey)
        )
        // In-run cursor over the deferred list. Deliberately not persisted:
        // each run (launch or sync completion) re-checks every deferred
        // conversation once. Still-pending conversations cost no fetch and do
        // not count against a retry batch's limit, so while nothing has
        // cleared that check is one short hold. A run interrupted inside a
        // cleared conversation restarts that conversation next run; its
        // already re-derived rows then derive to the same preview and change
        // nothing.
        //
        // The checkpoint, like the completion flag, is not account-scoped and
        // survives sign-out. A replacement account inherits it harmlessly:
        // the previous account's deferred conversation IDs match no row, so
        // each is retried through its participant hash (waiting out a pending
        // send on a same-hash conversation, like any other), which at most
        // re-derives the new account's same-participant rows under the
        // current derivation they were ingested with, and then drops.
        // Account teardown therefore does not clear it.
        var retryCursor: ChatPreviewRepair.RetryCursor?
        while !Task.isCancelled {
            // Never wait for sync while holding a lease: account teardown
            // waits for leases to drain before replacing the store.
            await syncWaiter.waitForCurrentSyncToComplete()
            guard !Task.isCancelled,
                  let lease = await accountWorkCoordinator.acquireAccountWorkLease(kind: .maintenance, for: request) else {
                return .stopped
            }
            let batchCheckpoint = checkpoint
            let batchRetryCursor = retryCursor
            let batch = await conversationMutationSerializer.performCleanupSensitiveMutation { [self] in
                await self.prepareAndSaveChatPreviewBatch(
                    pass: pass,
                    lease: lease,
                    checkpoint: batchCheckpoint,
                    retryAfter: batchRetryCursor
                )
            }
            var isComplete = false
            var isFinished = true
            if let batch {
                // Already persisted inside the hold; this is the same value.
                checkpoint = batchCheckpoint.advanced(by: batch)
                isComplete = checkpoint.isComplete
                switch batch.phase {
                case .mainScan, .legacyDeferredMigration:
                    // A drained scan with deferred conversations left falls
                    // through to one retry sweep this run (a send may have
                    // cleared while the scan ran); a legacy restart continues
                    // the scan, and a migrated legacy list continues with
                    // whichever phase the checkpoint is in.
                    isFinished = isComplete
                case .deferredRetry:
                    retryCursor = batch.retryCursor
                    isFinished = isComplete || batch.didDrain
                }
            }
            await accountWorkCoordinator.endRun(lease)
            guard batch != nil, !isFinished else {
                return isComplete ? .completed : .incomplete
            }
            await Task.yield()
        }
        return .stopped
    }

    /// Runs inside the cleanup-sensitive hold, and persists the advanced
    /// checkpoint there too, with no suspension after the save: the
    /// participant-set split and the hash-correcting merge take the same gate
    /// and read the deferred lists (`ChatPreviewRepair.DeferredRetryAnchors`)
    /// to leave deferred conversations' rows in place. Persisting after the
    /// hold would let a split queued on the gate run between a batch that
    /// deferred a conversation and the write that records it, and move rows
    /// the retry then never finds.
    private func prepareAndSaveChatPreviewBatch(
        pass: ChatPreviewPass,
        lease: SyncRun,
        checkpoint: ChatPreviewRepair.Checkpoint,
        retryAfter retryCursor: ChatPreviewRepair.RetryCursor?
    ) async -> ChatPreviewRepair.Batch? {
        guard !Task.isCancelled, await accountWorkCoordinator.isActiveRun(lease) else { return nil }
        let context = storage.makeBackgroundContext()
        context.mergePolicy = NSMergeByPropertyStoreTrumpMergePolicy
        do {
            let batch = try await pass.repair.prepareNextBatch(
                in: context,
                checkpoint: checkpoint,
                retryAfter: retryCursor,
                limit: Self.chatPreviewRepairBatchSize
            )
            guard !Task.isCancelled, await accountWorkCoordinator.isActiveRun(lease),
                  storage.saveIfNeeded(context) else {
                await context.perform { context.rollback() }
                return nil
            }
            persistChatPreviewCheckpoint(checkpoint.advanced(by: batch), replacing: checkpoint, for: pass)
            if !batch.changedMessageIDs.isEmpty,
               let accountContext = CacheCoordinator.shared.captureInvalidationAccountContext() {
                var plan = CacheCoordinator.CacheInvalidationPlan()
                plan.messageIdsToInvalidate = batch.changedMessageIDs
                CacheCoordinator.shared.applyInvalidationPlan(plan, accountContext: accountContext)
            }
            return batch
        } catch {
            await context.perform { context.rollback() }
            Log.error("Chat preview repair will retry after an incomplete batch", category: .conversation, error: error)
            return nil
        }
    }

    private func persistChatPreviewCheckpoint(
        _ next: ChatPreviewRepair.Checkpoint,
        replacing previous: ChatPreviewRepair.Checkpoint,
        for pass: ChatPreviewPass
    ) {
        // A retry sweep over still-pending conversations leaves the
        // checkpoint unchanged; skip the write then, since it repeats
        // on every sync completion while a send is retained. A retry
        // batch that is still inside a cleared conversation also leaves
        // it unchanged: only a finished conversation leaves the list.
        if next != previous {
            storage.migrationFlags.setString(next.encoded, forKey: pass.checkpointKey)
        }
        if next.isComplete {
            storage.migrationFlags.set(true, forKey: pass.migrationKey)
            storage.migrationFlags.setString(nil, forKey: pass.checkpointKey)
        }
    }

    // MARK: - Rich content verdict backfill

    /// Embeds the verdict epoch, so an epoch bump re-arms the pass: every stored
    /// verdict then reads as unknown and has to be stamped again.
    nonisolated static let richContentVerdictBackfillMigrationKey =
        "richContentVerdictBackfill.e\(CacheVersioning.richContentVerdictEpoch)"
    /// The scan cursor: the lowest message ID examined so far. Deliberately not
    /// one of `chatPreviewRepairCheckpointKeys`. That list is decoded as
    /// `ChatPreviewRepair.Checkpoint` and read by conversation maintenance for
    /// deferred conversations, and this pass defers none.
    nonisolated static let richContentVerdictBackfillCursorKey =
        richContentVerdictBackfillMigrationKey + ".cursor"
    private static let richContentVerdictBackfillTaskKey = "backfillRichContentVerdicts"
    /// Rows per account work lease. Each unstamped row reads an HTML file and
    /// runs the cleanup chain plus the classifier while the lease is held, and
    /// sign-out waits for outstanding leases without being able to cancel
    /// them. Smaller than `chatPreviewRepairBatchSize` because this pass does
    /// that work for every received row on every upgraded device, and again
    /// after each epoch bump, so a transition is far likelier to land on one
    /// of its leases. Every batch with a stamped row is a real save (one SQLite
    /// transaction plus persistent-history rows, kept until maintenance purges
    /// them). Unmeasured: tune with a trace if needed.
    static let richContentVerdictBackfillBatchSize = 10

    /// The leased work is CPU-bound and blocks sign-out, so it must not sit
    /// unscheduled the way `.background` jobs can. Tests pass nil to inherit
    /// their own priority, as for the other sweeps.
    private var richContentVerdictBackfillPriority: TaskPriority? {
        repairTaskPriority == nil ? nil : .utility
    }

#if DEBUG
    func waitForRichContentVerdictBackfillCompletion() async {
        await taskManager.waitForCompletion(of: Self.richContentVerdictBackfillTaskKey)
    }
#endif

    /// Stamps received rows that hold no rich-content verdict under the current
    /// epoch (`RichContentVerdictBackfill`), so their bubbles mount in final
    /// form instead of behind the loading pill.
    ///
    /// Its own task rather than a third pass inside `repairPersistedChatPreviews`:
    /// that function's early-out is the two preview flags, which are latched on
    /// every already-upgraded device, and a mailbox-wide scan holding
    /// `isChatPreviewRepairRunning` would refuse every sync-completion re-arm of
    /// the deferred-retry sweep for its whole duration. The verdict has no
    /// ordering dependency on the preview passes; `chatPreviewText` is not one
    /// of its inputs.
    ///
    /// Not account-scoped, like the preview passes' flags: every row the
    /// current build ingests is stamped as it is written, so a replacement
    /// account, or a fresh install that latches on an empty store, leaves
    /// nothing behind. An inherited cursor only makes the scan skip IDs above
    /// it, and those rows read as unknown until a bubble load stamps them.
    func backfillRichContentVerdicts() {
        guard !isRichContentVerdictBackfillRunning,
              !storage.migrationFlags.bool(forKey: Self.richContentVerdictBackfillMigrationKey) else {
            return
        }
        isRichContentVerdictBackfillRunning = true
        taskManager.run(
            Self.richContentVerdictBackfillTaskKey,
            priority: richContentVerdictBackfillPriority
        ) { [weak self] in
            guard let self else { return }
            defer { isRichContentVerdictBackfillRunning = false }
            guard let request = await accountWorkCoordinator.makeAccountWorkRequest() else { return }
            await runRichContentVerdictBackfill(request: request)
        }
    }

    private func runRichContentVerdictBackfill(request: AccountWorkRequest) async {
        let backfill = RichContentVerdictBackfill(htmlContentHandler: htmlContentHandler)
        var cursor = storage.migrationFlags.string(forKey: Self.richContentVerdictBackfillCursorKey)
        while !Task.isCancelled {
            // Never wait for sync while holding a lease: account teardown
            // waits for leases to drain before replacing the store. The wait
            // is only politeness (a run can start the moment it returns);
            // correctness against a concurrent sync save comes from the
            // batch context's store-trump policy and from the persister
            // stamping every row it writes.
            await syncWaiter.waitForCurrentSyncToComplete()
            guard !Task.isCancelled,
                  let lease = await accountWorkCoordinator.acquireAccountWorkLease(
                      kind: .maintenance,
                      for: request
                  ) else {
                return
            }
            // One release for every outcome of the batch: a leaked lease hangs
            // every later sign-out.
            let batch = await prepareAndSaveRichContentVerdictBatch(backfill, lease: lease, before: cursor)
            await accountWorkCoordinator.endRun(lease)
            // A failed or refused batch leaves the cursor where it was; the
            // next launch or sync completion retries from there.
            guard let batch, !batch.didDrain else { return }
            cursor = batch.lastMessageID
            await Task.yield()
        }
    }

    /// Takes no cleanup-sensitive gate and issues no cache invalidation: no
    /// content changed, and evicting `RenderedMessageCache` for every received
    /// row would throw away what open chats have loaded.
    private func prepareAndSaveRichContentVerdictBatch(
        _ backfill: RichContentVerdictBackfill,
        lease: SyncRun,
        before cursor: String?
    ) async -> RichContentVerdictBackfill.Batch? {
        guard !Task.isCancelled, await accountWorkCoordinator.isActiveRun(lease) else { return nil }
        let context = storage.makeBackgroundContext()
        // Store-trump: a row sync or the refresher stamped while this batch
        // classified carries the fresher verdict, and must win.
        context.mergePolicy = NSMergeByPropertyStoreTrumpMergePolicy
        do {
            let batch = try await backfill.prepareBatch(
                in: context,
                before: cursor,
                limit: Self.richContentVerdictBackfillBatchSize
            )
            guard !Task.isCancelled,
                  await accountWorkCoordinator.isActiveRun(lease),
                  await Self.saveOffMainActor(context, using: storage.saveIfNeeded) else {
                await context.perform { context.rollback() }
                return nil
            }
            // Written only after a successful save, with no suspension in
            // between, so a cursor never points past rows that were not stamped.
            if batch.didDrain {
                storage.migrationFlags.set(true, forKey: Self.richContentVerdictBackfillMigrationKey)
                storage.migrationFlags.setString(nil, forKey: Self.richContentVerdictBackfillCursorKey)
            } else {
                storage.migrationFlags.setString(
                    batch.lastMessageID,
                    forKey: Self.richContentVerdictBackfillCursorKey
                )
            }
            return batch
        } catch {
            await context.perform { context.rollback() }
            Log.error("Rich content verdict backfill will retry after an incomplete batch", category: .conversation, error: error)
            return nil
        }
    }

    /// `storage.saveIfNeeded` blocks its caller for the commit (and for the
    /// store lock when a sync save is in flight). The preview passes rarely
    /// have anything to save; this pass saves nearly every batch, hundreds or
    /// thousands of times on a large mailbox, so the wait is kept off the
    /// main actor. The save seam itself stays injectable for tests.
    private nonisolated static func saveOffMainActor(
        _ context: NSManagedObjectContext,
        using saveIfNeeded: @escaping (NSManagedObjectContext) -> Bool
    ) async -> Bool {
        saveIfNeeded(context)
    }

    func refreshConversationNames() {
        // V6: refresh stored conversation display names only. Rollup metadata stays sync-owned.
        let hasRefreshedKey = Self.conversationNameRefreshMigrationKey
        let migrationFlags = storage.migrationFlags
        guard !migrationFlags.bool(forKey: hasRefreshedKey) else { return }
        // An empty store means the initial sync has not landed yet (fresh
        // install), not that every name is refreshed — leave the flag unset so
        // the migration still runs once conversations exist.
        guard storeHasConversations() else { return }

        taskManager.run("refreshNames") { [weak self] in
            guard let self = self else { return }
            let context = storage.makeBackgroundContext()
            await conversationManager.updateAllConversationDisplayNames(in: context)
            guard storage.saveIfNeeded(context) else { return }
            migrationFlags.set(true, forKey: hasRefreshedKey)
            Log.info("Refreshed conversation display names (V6)", category: .conversation)
        }
    }

    /// Re-derives identifier-derived list conversation titles once per launch
    /// (no one-shot migration flag): a `ParsedListId` heuristic improvement
    /// then heals titles stored under the old heuristic at the next launch,
    /// instead of waiting for each list's next arrival to re-run rollups or
    /// for a name-refresh key bump. The candidate scan is attribute-only over
    /// list conversations, so a clean store costs one small fetch per launch.
    func repairListConversationTitles() {
        guard !isListConversationTitleRepairRunning,
              !hasCompletedListConversationTitleRepair else { return }
        isListConversationTitleRepairRunning = true

        taskManager.run("repairListConversationTitles", priority: repairTaskPriority) { [weak self] in
            guard let self = self else { return }
            defer { isListConversationTitleRepairRunning = false }

            // Mirror the preview repair: a running sync may be mid-save on
            // these rows; let it finish before rewriting titles.
            await syncWaiter.waitForCurrentSyncToComplete()
            guard !Task.isCancelled else { return }

            let context = storage.makeBackgroundContext()
            // Store-trump on purpose, mirroring the preview repair (opposite
            // of the app-wide object-trump default): a sync run starting
            // after the wait can persist a fresher sender-derived title while
            // this pass holds pre-sync rows, and a stale title written here
            // would be permanent — a healed human title is never a repair
            // candidate again, and this pass has no sync-completion re-arm.
            context.mergePolicy = NSMergeByPropertyStoreTrumpMergePolicy
            guard let repairedCount = await conversationManager.repairIdentifierDerivedListConversationTitles(in: context) else {
                // nil = the candidate scan's fetch failed, which is not "no
                // candidates": latching completion here would skip the repair
                // for the rest of the process. Leave the pass incomplete so a
                // later runLaunchRepairsIfNeeded() retries it this launch,
                // mirroring the failed-save path below.
                return
            }
            if repairedCount > 0 {
                // A failed save leaves the pass incomplete so a later
                // runLaunchRepairsIfNeeded() can retry it this launch.
                guard storage.saveIfNeeded(context) else { return }
                Log.info(
                    "Repaired \(repairedCount) identifier-derived list conversation titles",
                    category: .conversation
                )
            }
            hasCompletedListConversationTitleRepair = true
        }
    }

    func repairMissingConversationPreviews() {
        // Runs once per launch, not once per install: interrupted syncs can
        // re-create both broken states (missing previews and stranded
        // message-less shells) at any time, so a one-shot migration flag
        // leaves later breakage visible forever.
        guard !isConversationPreviewRepairRunning,
              !hasCompletedConversationPreviewRepair else { return }
        isConversationPreviewRepairRunning = true

        let hasRepairedKey = Self.conversationPreviewRepairMigrationKey
        let migrationFlags = storage.migrationFlags

        taskManager.run(Self.repairMissingConversationPreviewsTaskKey, priority: repairTaskPriority) { [weak self] in
            guard let self = self else { return }
            var didCompleteRepair = false
            defer {
                isConversationPreviewRepairRunning = false
                if didCompleteRepair {
                    hasCompletedConversationPreviewRepair = true
                }
            }

            // A running sync may have saved a conversation shell whose first
            // message has not persisted yet; sweeping shells mid-sync could
            // archive a row that is about to receive its message.
            await syncWaiter.waitForCurrentSyncToComplete()
            guard !Task.isCancelled else { return }

            // Sampled before the sweep: an empty drain on an empty store must
            // not count as completion (see the didDrain gate below).
            let storeHadConversations = storeHasConversations()

            let context = storage.makeBackgroundContext()
            // Store-trump on purpose (opposite of the app-wide object-trump
            // default): if live sync saves fresher rollups while this pass
            // holds stale in-memory values, the store version must win; the
            // sync-completion re-arm re-sweeps anything still broken.
            context.mergePolicy = NSMergeByPropertyStoreTrumpMergePolicy

            guard let archivedCount = await conversationMutationSerializer
                .performCleanupSensitiveMutation(operation: { [self] in
                    await self.archiveMessagelessConversationsAndSave(in: context)
                }) else {
                return
            }
            if archivedCount > 0 {
                Log.info("Archived \(archivedCount) stranded message-less conversations", category: .conversation)
            }

            var totalRepairedCount = 0
            while !Task.isCancelled {
                let result = await conversationManager.repairMissingConversationPreviews(in: context)
                if result.repairedCount > 0 {
                    guard storage.saveIfNeeded(context) else { return }
                    totalRepairedCount += result.repairedCount
                }

                if result.didDrain {
                    if totalRepairedCount > 0 {
                        Log.info("Repaired missing conversation previews: \(totalRepairedCount)", category: .conversation)
                    }
                    // Draining an empty store says nothing about repair health:
                    // on a fresh install this pass can beat the first sync run's
                    // registration. Stay armed so the sync-completion re-arm
                    // sweeps the store once data actually exists.
                    guard storeHadConversations || hasObservedSyncCompletionThisLaunch else { return }
                    migrationFlags.set(true, forKey: hasRepairedKey)
                    didCompleteRepair = true
                    return
                }

                guard result.repairedCount > 0 else {
                    if totalRepairedCount > 0 {
                        Log.info("Repaired missing conversation previews: \(totalRepairedCount)", category: .conversation)
                    }
                    return
                }

                await Task.yield()
            }
        }
    }

    /// The stranded-shell sweep is destructive conversation maintenance. Read
    /// pending anchors and persist the archive while holding the same gate as
    /// optimistic graph creation, failing closed if either operation fails.
    private func archiveMessagelessConversationsAndSave(
        in context: NSManagedObjectContext
    ) async -> Int? {
        let pendingConversationIDs: Set<UUID>? = await context.perform {
            do {
                let sends = try context.fetch(OutboundSendMutationRecord.fetchRequest())
                let drafts = try context.fetch(NSFetchRequest<ChatReplyDraft>(entityName: "ChatReplyDraft"))
                return Set(sends.compactMap(\.conversationId)).union(drafts.map(\.conversationId))
            } catch {
                Log.error(
                    "Failed to fetch pending sends before stranded-shell cleanup",
                    category: .conversation,
                    error: error
                )
                return nil
            }
        }
        guard let pendingConversationIDs else { return nil }

        let archivedCount = await conversationManager.archiveMessagelessConversations(
            in: context,
            excludingConversationIDs: pendingConversationIDs
        )
        guard archivedCount == 0 || storage.saveIfNeeded(context) else {
            Log.error(
                "Failed to save \(archivedCount) archived message-less conversations; skipping preview repair",
                category: .conversation
            )
            return nil
        }
        return archivedCount
    }

    /// Whether any conversations exist in the persistent store. Gates the
    /// launch-time name refresh and preview repair so neither treats a
    /// fresh install's empty store as successful completion.
    private func storeHasConversations() -> Bool {
        let request = Conversation.fetchRequest()
        request.includesPendingChanges = false

        do {
            return try storage.viewContext.count(for: request) > 0
        } catch {
            Log.error("Failed to count conversations for launch repair passes", category: .conversation, error: error)
            return false
        }
    }
}
