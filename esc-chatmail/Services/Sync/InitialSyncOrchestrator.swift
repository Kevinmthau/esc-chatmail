import Foundation
import CoreData

/// Result of initial sync operation
struct InitialSyncResult {
    let messagesProcessed: Int
    let conversationCount: Int
    let duration: TimeInterval
    let hadWarnings: Bool
}

struct InitialSyncCompletionDisposition: Equatable {
    let shouldAdvanceHistoryId: Bool
    let hadWarnings: Bool
}

/// Result of the completion policy: whether the run ends with warnings, and —
/// when the failure tracker was consulted — the staged advancement plan whose
/// success-side effects must be committed only after the final save.
struct InitialSyncCompletionOutcome {
    let hadWarnings: Bool
    let advancePlan: SyncFailureTracker.HistoryAdvancePlan?
}

/// Orchestrates the initial full sync from Gmail
///
/// Responsibilities:
/// - Fetch user profile and aliases
/// - Fetch and save labels
/// - Stream process all messages since install
/// - Update conversation rollups
/// - Handle failure recovery with retries
@MainActor
final class InitialSyncOrchestrator {

    // MARK: - Dependencies

    private let messageFetcher: MessageFetcher
    private let messagePersister: MessagePersister
    private let conversationManager: ConversationManager
    private let dataCleanupService: DataCleanupService
    private let attachmentDownloader: AttachmentDownloader
    private let coreDataStack: CoreDataStack
    private let failureTracker: SyncFailureTracker
    private let performanceLogger: CoreDataPerformanceLogger
    private let rollupMutationSerializer: ConversationRollupMutationSerializer
    private let log = LogCategory.sync.logger

    private var myAliases: Set<String> = []
    private var sendAsAliases: [SendAsAlias] = []

    // MARK: - Initialization

    init(
        messageFetcher: MessageFetcher,
        messagePersister: MessagePersister,
        conversationManager: ConversationManager,
        dataCleanupService: DataCleanupService,
        attachmentDownloader: AttachmentDownloader,
        coreDataStack: CoreDataStack,
        failureTracker: SyncFailureTracker = .shared,
        performanceLogger: CoreDataPerformanceLogger = .shared,
        rollupMutationSerializer: ConversationRollupMutationSerializer = .shared
    ) {
        self.messageFetcher = messageFetcher
        self.messagePersister = messagePersister
        self.conversationManager = conversationManager
        self.dataCleanupService = dataCleanupService
        self.attachmentDownloader = attachmentDownloader
        self.coreDataStack = coreDataStack
        self.failureTracker = failureTracker
        self.performanceLogger = performanceLogger
        self.rollupMutationSerializer = rollupMutationSerializer
    }

    // MARK: - Public API

    /// Performs initial full sync
    /// - Parameter progressHandler: Callback for progress updates
    /// - Returns: Result of the sync operation
    func performSync(
        progressHandler: @escaping (Double, String) -> Void
    ) async throws -> InitialSyncResult {
        let syncStartTime = CFAbsoluteTimeGetCurrent()
        var timing = SyncTimingRecorder(syncType: "initial", runStartedAt: syncStartTime)
        let signpostID = performanceLogger.beginOperation("InitialSync")

        let context = coreDataStack.newBackgroundContext()
        let modificationTransaction = await ModificationTracker.shared.beginTransaction()
        var committedModificationTransaction = false

        // Run one-time cleanup
        let cleanupTimer = timing.start("initialCleanup")
        await runInitialCleanupIfNeeded(in: context)
        timing.finish(cleanupTimer)

        do {
            // Phase 1: Fetch profile and aliases
            progressHandler(0.05, "Fetching profile...")
            let profileTimer = timing.start("profileAndAliases")
            let (profile, aliases, validSendAsAliases) = try await fetchProfileAndAliases()
            sendAsAliases = validSendAsAliases
            myAliases = await AliasManager.shared.setAliases(Set([profile.emailAddress] + aliases))
            await SendAsAliasManager.shared.setAliases(validSendAsAliases)
            try await messagePersister.saveAccount(
                profile: profile,
                aliases: aliases,
                sendAsAliases: validSendAsAliases,
                in: context,
                saveHistoryId: false
            )
            timing.finish(profileTimer, detail: "aliases=\(aliases.count)")

            // Phase 2: Fetch and save labels
            progressHandler(0.1, "Fetching labels...")
            let labelsTimer = timing.start("labels")
            let labels = try await messageFetcher.listLabels()
            await messagePersister.saveLabels(labels, in: context)
            let labelIds = await messagePersister.prefetchLabelIds(in: context)
            timing.finish(labelsTimer, detail: "labels=\(labels.count)")

            // Phase 3: Fetch and process messages
            progressHandler(0.2, "Fetching messages...")
            let query = buildInitialSyncQuery()
            log.info("Initial sync query: \(query)")

            let messagesTimer = timing.start("fetchAndProcessMessages")
            let result = try await fetchAndProcessMessages(
                query: query,
                labelIds: labelIds,
                modificationTransaction: modificationTransaction,
                context: context,
                progressHandler: { progress, status in
                    // Map 0-1 to 0.2-0.85
                    progressHandler(0.2 + progress * 0.65, status)
                }
            )
            timing.finish(
                messagesTimer,
                detail: "processed=\(result.totalProcessed) success=\(result.successfulCount) failed=\(result.failedIds.count)"
            )

            log.info("Initial sync: processed=\(result.totalProcessed), success=\(result.successfulCount), failed=\(result.failedIds.count)")

            // Phase 4: Handle failures and determine historyId advancement
            let completionTimer = timing.start("completionPolicy")
            let completion = try await handleSyncCompletion(
                result: result,
                profile: profile,
                labelIds: labelIds,
                modificationTransaction: modificationTransaction,
                context: context
            )
            let syncCompletedWithWarnings = completion.hadWarnings
            timing.finish(completionTimer, detail: "warnings=\(syncCompletedWithWarnings)")

            // Phase 5: Keep historyId and rollup updates in the same save so later syncs
            // never advance past message changes without the derived conversation state.
            // Per-page rollups claim as they go, so the pending set here holds only what
            // the failed-message retries in Phase 4 touched after the last page save.
            let modifiedConversations = await ModificationTracker.shared.modifiedConversations(in: modificationTransaction)
            let trackedDisplayNameOnlyConversations = await ModificationTracker.shared
                .displayNameOnlyConversations(in: modificationTransaction)
            let displayNameOnlyConversations = trackedDisplayNameOnlyConversations.subtracting(modifiedConversations)
            let affectedConversationIDs = modifiedConversations.union(displayNameOnlyConversations)

            progressHandler(0.85, "Updating conversations...")
            progressHandler(0.95, "Saving changes...")
            let persistenceTimer = timing.start("conversationUpdatesAndSave")
            let conversationManager = self.conversationManager
            let coreDataStack = self.coreDataStack
            try await rollupMutationSerializer.performThrowingSyncMutation(
                conversationIDs: affectedConversationIDs,
                in: context
            ) {
                if !modifiedConversations.isEmpty {
                    await conversationManager.updateRollupsForModifiedConversations(
                        conversationIDs: modifiedConversations,
                        in: context
                    )
                }
                if !displayNameOnlyConversations.isEmpty {
                    await conversationManager.updateConversationDisplayNames(
                        conversationIDs: displayNameOnlyConversations,
                        in: context
                    )
                }
                try await coreDataStack.saveAsync(context: context)
            }
            timing.finish(
                persistenceTimer,
                detail: "rollups=\(modifiedConversations.count) names=\(displayNameOnlyConversations.count)"
            )
            log.info("Initial sync save successful")

            _ = await ModificationTracker.shared.commitTransaction(modificationTransaction)
            committedModificationTransaction = true
            await ModificationTracker.shared.consumeCommittedTransaction(modificationTransaction)

            // The save above committed the staged ledger state; only now may the
            // tracker's success state change. On the warnings path there is no
            // plan — deferred rows stay tracked and the counter stands.
            if let advancePlan = completion.advancePlan {
                await failureTracker.commit(advancePlan)
            }

            let conversationCount = await countConversations(in: context)

            // Record successful sync time
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: SyncConfig.lastSuccessfulSyncTimeKey)

            // Queue attachment downloads
            Task {
                await attachmentDownloader.enqueueAllPendingAttachments()
            }

            let totalDuration = CFAbsoluteTimeGetCurrent() - syncStartTime
            performanceLogger.endOperation("InitialSync", signpostID: signpostID)
            performanceLogger.logSyncSummary(
                messagesProcessed: result.successfulCount,
                conversationsUpdated: conversationCount,
                totalDuration: totalDuration
            )
            timing.finishRun(
                outcome: "success messages=\(result.successfulCount) conversations=\(conversationCount) warnings=\(syncCompletedWithWarnings)"
            )

            return InitialSyncResult(
                messagesProcessed: result.successfulCount,
                conversationCount: conversationCount,
                duration: totalDuration,
                hadWarnings: syncCompletedWithWarnings
            )

        } catch {
            if !committedModificationTransaction {
                await ModificationTracker.shared.rollbackTransaction(modificationTransaction)
            }
            performanceLogger.endOperation("InitialSync", signpostID: signpostID)
            timing.finishRun(outcome: "failed error=\(error.localizedDescription)")
            log.error("Initial sync failed", error: error)
            throw error
        }
    }

    // MARK: - Private Methods

    private func runInitialCleanupIfNeeded(in context: NSManagedObjectContext) async {
        let hasDoneCleanup = UserDefaults.standard.bool(forKey: "hasDoneDuplicateCleanupV1")
        if !hasDoneCleanup {
            await dataCleanupService.runFullCleanup(in: context)
            UserDefaults.standard.set(true, forKey: "hasDoneDuplicateCleanupV1")
        }
    }

    private func fetchProfileAndAliases() async throws -> (GmailProfile, [String], [SendAsAlias]) {
        // Independent requests — run them concurrently. The fetcher is bound
        // to a local first so the async lets capture a constant rather than
        // self (strict-concurrency robustness).
        let fetcher = messageFetcher
        async let profileRequest = fetcher.getProfile()
        async let sendAsRequest = fetcher.listSendAs()
        let (profile, sendAsList) = try await (profileRequest, sendAsRequest)
        let sendAsAliases = SendAsAlias.validAliases(
            from: sendAsList,
            accountEmail: profile.emailAddress
        )
        let aliases = sendAsAliases.map(\.emailAddress)
        return (profile, aliases, sendAsAliases)
    }

    private func buildInitialSyncQuery() -> String {
        let installTimestamp = UserDefaults.standard.double(forKey: "installTimestamp")

        if installTimestamp > 0 {
            log.info("Fetching messages after install time: \(Date(timeIntervalSince1970: installTimestamp))")
        } else {
            log.warning("No install timestamp found, using fallback window")
        }

        return SyncTimeCalculator.buildSyncQuery(config: .initialSync)
    }

    private func fetchAndProcessMessages(
        query: String,
        labelIds: Set<String>,
        modificationTransaction: ModificationTracker.Transaction,
        context: NSManagedObjectContext,
        progressHandler: @escaping (Double, String) -> Void
    ) async throws -> BatchProcessingResult {
        return try await MessageListPaginator.fetchAndProcess(
            query: query,
            messageFetcher: messageFetcher
        ) { checkpoint in
            let progress = Self.streamingProgressFraction(for: checkpoint)
            await MainActor.run {
                progressHandler(
                    progress,
                    "Processing messages... \(checkpoint.processedCount)/\(checkpoint.listedCount)"
                )
            }
        } messageHandler: { [messagePersister, myAliases, sendAsAliases] messages in
            // Capture dependencies strongly to prevent message loss if orchestrator is deallocated
            try await messagePersister.saveMessages(
                messages,
                labelIds: labelIds,
                myAliases: myAliases,
                sendAsAliases: sendAsAliases,
                modificationTransaction: modificationTransaction,
                in: context
            )
        } pageCompletion: { [conversationManager, coreDataStack, rollupMutationSerializer] in
            // Roll up each page's modified conversations before its save so messages
            // and their derived state (snippet, displayName, counts) persist together;
            // an interrupted run then keeps every saved page fully presentable.
            let pageConversationIDs = await ModificationTracker.shared
                .claimPendingRollupConversations(in: modificationTransaction)
            try await rollupMutationSerializer.performThrowingSyncMutation(
                conversationIDs: pageConversationIDs,
                in: context
            ) {
                if !pageConversationIDs.isEmpty {
                    await conversationManager.updateRollupsForModifiedConversations(
                        conversationIDs: pageConversationIDs,
                        in: context
                    )
                }
                try await coreDataStack.saveAsync(context: context)
            }
        }
    }

    nonisolated private static func streamingProgressFraction(for checkpoint: PagedSyncCheckpoint) -> Double {
        let denominator = checkpoint.isComplete
            ? max(checkpoint.listedCount, 1)
            : max(checkpoint.listedCount + SyncConfig.maxMessagesPerRequest, 1)
        let progress = Double(checkpoint.processedCount) / Double(denominator)
        return min(checkpoint.isComplete ? 1.0 : 0.98, progress)
    }

    func handleSyncCompletion(
        result: BatchProcessingResult,
        profile: GmailProfile,
        labelIds: Set<String>,
        modificationTransaction: ModificationTracker.Transaction,
        context: NSManagedObjectContext
    ) async throws -> InitialSyncCompletionOutcome {
        if result.hasFailures {
            log.warning("Initial sync has \(result.blockingFailureIds.count) failed messages")

            // Retry failed messages (fetch failures and persistence failures
            // alike). Quota exhaustion propagates: the initial sync aborts
            // without advancing historyId or recording the remaining IDs as
            // failures, and resumes on a later run.
            let retryOutcome = try await BatchProcessor.retryFailedMessages(
                failedIds: result.blockingFailureIds,
                messageFetcher: messageFetcher
            ) { [messagePersister, myAliases, sendAsAliases] messages in
                // Capture dependencies strongly to prevent message loss if orchestrator is deallocated
                try await messagePersister.saveMessages(
                    messages,
                    labelIds: labelIds,
                    myAliases: myAliases,
                    sendAsAliases: sendAsAliases,
                    modificationTransaction: modificationTransaction,
                    in: context
                )
            }
            let stillFailedIds = retryOutcome.blockingFailureIds

            let disposition = Self.completionDisposition(
                hadInitialFailures: true,
                permanentlyFailedCount: stillFailedIds.count
            )

            if disposition.hadWarnings {
                log.warning("\(stillFailedIds.count) messages permanently failed - keeping historyId unset so initial sync can retry safely")
                // Stages deferred ledger rows into the sync context; they commit
                // with the run's final save. There is no cursor yet, so no
                // sourceHistoryId to stamp.
                await failureTracker.recordFailure(
                    fetchFailedIds: retryOutcome.fetchFailedIds,
                    persistenceFailedIds: retryOutcome.persistence.failedIds,
                    sourceHistoryId: nil,
                    in: context
                )
                return InitialSyncCompletionOutcome(hadWarnings: true, advancePlan: nil)
            }

            let advancePlan = await failureTracker.planHistoryAdvance(hadFailures: false, in: context)
            if advancePlan.shouldAdvance {
                log.info("All failed messages recovered on retry - advancing historyId")
                await messagePersister.setAccountHistoryId(profile.historyId, in: context)
            } else {
                log.error("Recovered messages but failure-ledger cleanup could not be planned - keeping historyId unset")
            }
            return InitialSyncCompletionOutcome(
                hadWarnings: !advancePlan.shouldAdvance,
                advancePlan: advancePlan
            )
        }

        let advancePlan = await failureTracker.planHistoryAdvance(hadFailures: false, in: context)
        if advancePlan.shouldAdvance {
            log.info("All messages fetched successfully - advancing historyId to \(profile.historyId)")
            await messagePersister.setAccountHistoryId(profile.historyId, in: context)
        } else {
            log.error("Initial sync succeeded but failure-ledger cleanup could not be planned - keeping historyId unset")
        }
        return InitialSyncCompletionOutcome(
            hadWarnings: !advancePlan.shouldAdvance,
            advancePlan: advancePlan
        )
    }

    nonisolated static func completionDisposition(
        hadInitialFailures: Bool,
        permanentlyFailedCount: Int
    ) -> InitialSyncCompletionDisposition {
        guard hadInitialFailures else {
            return InitialSyncCompletionDisposition(
                shouldAdvanceHistoryId: true,
                hadWarnings: false
            )
        }

        return InitialSyncCompletionDisposition(
            shouldAdvanceHistoryId: permanentlyFailedCount == 0,
            hadWarnings: permanentlyFailedCount > 0
        )
    }

    private func countConversations(in context: NSManagedObjectContext) async -> Int {
        await context.perform {
            let request = Conversation.fetchRequest()
            return (try? context.count(for: request)) ?? 0
        }
    }
}
