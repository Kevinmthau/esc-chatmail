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
    init(
        storage: StorageDependencies,
        conversationManager: ConversationManager,
        syncWaiter: any ForegroundSyncPerforming,
        notificationCenter: NotificationCenter = .default
    ) {
        self.storage = storage
        self.conversationManager = conversationManager
        self.syncWaiter = syncWaiter
        self.notificationCenter = notificationCenter
        bindSyncCompletionRepairRearm()
    }

    /// Runs the launch passes. Called from the list's `onAppear`; each pass
    /// owns its own per-launch guard, so repeat calls are cheap no-ops.
    func runLaunchRepairsIfNeeded() {
        refreshConversationNames()
        repairListConversationTitles()
        repairMissingConversationPreviews()
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
            }
            .store(in: &cancellables)
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

        taskManager.run("repairListConversationTitles", priority: .background) { [weak self] in
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
            let repairedCount = await conversationManager.repairIdentifierDerivedListConversationTitles(in: context)
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

        taskManager.run(Self.repairMissingConversationPreviewsTaskKey, priority: .background) { [weak self] in
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

            let archivedCount = await conversationManager.archiveMessagelessConversations(in: context)
            if archivedCount > 0 {
                guard storage.saveIfNeeded(context) else {
                    Log.error(
                        "Failed to save \(archivedCount) archived message-less conversations; skipping preview repair",
                        category: .conversation
                    )
                    return
                }
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
