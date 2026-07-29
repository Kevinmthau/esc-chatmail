import Foundation
import CoreData

/// Result of incremental sync operation
struct IncrementalSyncResult {
    let newMessagesCount: Int
    let labelChangesProcessed: Int
    let hadWarnings: Bool
}

/// Orchestrates incremental sync using Gmail History API
///
/// Uses composable SyncPhase implementations for each stage:
/// 1. HistoryCollectionPhase - Fetch history changes
/// 2. MessageFetchPhase - Fetch and persist new messages
/// 3. LabelProcessingPhase - Process label changes
/// 4. ReconciliationPhase - Catch missed changes
/// 5. ConversationUpdatePhase - Update conversation rollups
@MainActor
final class IncrementalSyncOrchestrator {

    // MARK: - Dependencies

    private let messageFetcher: MessageFetcher
    private let messagePersister: MessagePersister
    private let historyProcessor: HistoryProcessor
    private let conversationManager: ConversationManager
    private let dataCleanupService: DataCleanupService
    private let reconciliation: SyncReconciliation
    private let coreDataStack: CoreDataStack
    private let failureTracker: SyncFailureTracker
    private let aliasRefreshPolicy: SendAsAliasRefreshPolicy
    private let rollupMutationSerializer: ConversationRollupMutationSerializer
    private let log = LogCategory.sync.logger

    private var myAliases: Set<String> = []
    private var sendAsAliases: [SendAsAlias] = []

    // MARK: - Phases (lazily initialized)

    private lazy var historyCollectionPhase = HistoryCollectionPhase(
        messageFetcher: messageFetcher,
        historyProcessor: historyProcessor
    )

    private lazy var messageFetchPhase = MessageFetchPhase(
        messageFetcher: messageFetcher,
        messagePersister: messagePersister
    )

    private lazy var labelProcessingPhase = LabelProcessingPhase(
        historyProcessor: historyProcessor
    )

    private lazy var reconciliationPhase = ReconciliationPhase(
        reconciliation: reconciliation,
        messageFetcher: messageFetcher,
        messagePersister: messagePersister
    )

    private lazy var conversationUpdatePhase = ConversationUpdatePhase(
        conversationManager: conversationManager
    )

    // MARK: - Initialization

    init(
        messageFetcher: MessageFetcher,
        messagePersister: MessagePersister,
        historyProcessor: HistoryProcessor,
        conversationManager: ConversationManager,
        dataCleanupService: DataCleanupService,
        reconciliation: SyncReconciliation,
        coreDataStack: CoreDataStack,
        failureTracker: SyncFailureTracker = .shared,
        aliasRefreshPolicy: SendAsAliasRefreshPolicy = SendAsAliasRefreshPolicy(),
        rollupMutationSerializer: ConversationRollupMutationSerializer = .shared
    ) {
        self.messageFetcher = messageFetcher
        self.messagePersister = messagePersister
        self.historyProcessor = historyProcessor
        self.conversationManager = conversationManager
        self.dataCleanupService = dataCleanupService
        self.reconciliation = reconciliation
        self.coreDataStack = coreDataStack
        self.failureTracker = failureTracker
        self.aliasRefreshPolicy = aliasRefreshPolicy
        self.rollupMutationSerializer = rollupMutationSerializer
    }

    // MARK: - Public API

    /// Performs incremental sync using composable phases
    func performSync(
        progressHandler: @escaping (Double, String) -> Void,
        initialSyncFallback: @escaping () async throws -> Void
    ) async throws -> IncrementalSyncResult {
        let syncStartTime = Date()
        var timing = SyncTimingRecorder(syncType: "incremental")

        // Fetch account data
        let accountTimer = timing.start("accountData")
        let accountData: AccountData?
        do {
            accountData = try await messagePersister.fetchAccountData()
        } catch {
            timing.finish(accountTimer, detail: "failed=true")
            timing.finishRun(outcome: "failed error=\(error.localizedDescription)")
            throw error
        }
        timing.finish(accountTimer, detail: "hasHistory=\(accountData?.historyId != nil)")

        guard let accountData = accountData, let historyId = accountData.historyId else {
            log.info("No account/historyId found, performing initial sync")
            let fallbackTimer = timing.start("initialSyncFallback")
            do {
                try await initialSyncFallback()
                timing.finish(fallbackTimer)
                timing.finishRun(outcome: "initialFallback")
            } catch {
                timing.finish(fallbackTimer, detail: "failed=true")
                timing.finishRun(outcome: "failed error=\(error.localizedDescription)")
                throw error
            }
            return IncrementalSyncResult(newMessagesCount: 0, labelChangesProcessed: 0, hadWarnings: false)
        }

        log.info("Starting incremental sync with historyId: \(historyId)")
        let setupTimer = timing.start("setup")

        let context = coreDataStack.newBackgroundContext()
        let modificationTransaction = await ModificationTracker.shared.beginTransaction()
        var committedModificationTransaction = false
        sendAsAliases = await refreshSendAsAliases(accountEmail: accountData.email, in: context)
        myAliases = await AliasManager.shared.getAliases(from: context)
        let labelIds = await messagePersister.prefetchLabelIds(in: context)
        timing.finish(setupTimer, detail: "aliases=\(myAliases.count) sendAs=\(sendAsAliases.count) labels=\(labelIds.count)")

        let historyCollectionContext = SyncPhaseContext(
            coreDataContext: context,
            labelIds: labelIds,
            myAliases: myAliases,
            sendAsAliases: sendAsAliases,
            modificationTransaction: modificationTransaction,
            syncStartTime: syncStartTime,
            progressHandler: progressHandler,
            failureTracker: failureTracker
        )

        do {
            // Phase 1: Collect all history
            let historyTimer = timing.start("historyCollection")
            let historyResult = try await historyCollectionPhase.execute(
                input: historyId,
                context: historyCollectionContext
            )
            timing.finish(
                historyTimer,
                detail: "records=\(historyResult.records.count) newMessages=\(historyResult.newMessageIds.count) truncated=\(historyResult.wasTruncated)"
            )
            let allowsIntermediateContextSaves = Self.allowsIntermediateContextSaves(
                for: historyResult.records
            )
            let phaseContext = SyncPhaseContext(
                coreDataContext: context,
                labelIds: labelIds,
                myAliases: myAliases,
                sendAsAliases: sendAsAliases,
                modificationTransaction: modificationTransaction,
                allowsIntermediateContextSaves: allowsIntermediateContextSaves,
                syncStartTime: syncStartTime,
                progressHandler: progressHandler,
                failureTracker: failureTracker
            )

            // Phase 2: Fetch new messages
            let messageFetchTimer = timing.start("messageFetch")
            let fetchResult = try await messageFetchPhase.execute(
                input: historyResult.newMessageIds,
                context: phaseContext
            )
            timing.finish(
                messageFetchTimer,
                detail: "success=\(fetchResult.successfulCount) failed=\(fetchResult.failedIds.count)"
            )

            // Phase 2b: Retry previously abandoned messages. Their failures must not
            // influence historyId advancement — the cursor moved past them when they
            // were abandoned. Tracker bookkeeping happens after the final save below.
            let abandonedRetryTimer = timing.start("abandonedRetry")
            let abandonedOutcome = await retryAbandonedMessages(phaseContext: phaseContext)
            timing.finish(
                abandonedRetryTimer,
                detail: "recovered=\(abandonedOutcome.recoveredIds.count) gone=\(abandonedOutcome.goneIds.count) failed=\(abandonedOutcome.failedIds.count)"
            )

            // Phase 3: Process label changes (AFTER messages are fetched)
            let labelTimer = timing.start("labelProcessing")
            try await labelProcessingPhase.execute(
                input: historyResult.records,
                context: phaseContext
            )
            timing.finish(labelTimer, detail: "records=\(historyResult.records.count)")
            if phaseContext.allowsIntermediateContextSaves {
                let flushTimer = timing.start("intermediateFlush")
                let intermediateRollupConversationIDs = await ModificationTracker.shared
                    .modifiedConversations(in: modificationTransaction)
                let trackedIntermediateDisplayNameConversationIDs = await ModificationTracker.shared
                    .displayNameOnlyConversations(in: modificationTransaction)
                let intermediateDisplayNameConversationIDs = trackedIntermediateDisplayNameConversationIDs
                    .subtracting(intermediateRollupConversationIDs)
                let intermediateAffectedConversationIDs = intermediateRollupConversationIDs
                    .union(intermediateDisplayNameConversationIDs)
                let conversationManager = self.conversationManager
                let coreDataStack = self.coreDataStack
                try await rollupMutationSerializer.performThrowingSyncMutation(
                    conversationIDs: intermediateAffectedConversationIDs,
                    in: context
                ) {
                    if !intermediateRollupConversationIDs.isEmpty {
                        await conversationManager.updateRollupsForModifiedConversations(
                            conversationIDs: intermediateRollupConversationIDs,
                            in: context
                        )
                    }
                    if !intermediateDisplayNameConversationIDs.isEmpty {
                        await conversationManager.updateConversationDisplayNames(
                            conversationIDs: intermediateDisplayNameConversationIDs,
                            in: context
                        )
                    }
                    try await coreDataStack.saveAsync(context: context)
                }
                log.debug("Flushed sync changes after label processing")
                timing.finish(flushTimer)
            } else {
                log.debug("Deferring mid-sync flush because history includes destructive local changes")
            }

            // Phase 4: Reconciliation
            // The missed-message check inside the phase stays per-sync by
            // design: it is the cheap (single list call) safety net against
            // dropped history/push events. Label reconciliation is the
            // expensive half (~1 metadata GET per recent message) and is
            // TTL-gated below.
            let noHistoryChanges = historyResult.records.isEmpty && historyResult.newMessageIds.isEmpty
            let shouldSkipReconciliation = Self.shouldSkipLabelReconciliation(
                noHistoryChanges: noHistoryChanges,
                lastReconciliation: UserDefaults.standard.double(forKey: SyncConfig.lastReconciliationTimeKey),
                now: Date().timeIntervalSince1970
            )
            let reconciliationTimer = timing.start("reconciliation")
            let reconciliationResult = try await reconciliationPhase.execute(
                input: ReconciliationInput(skipLabelReconciliation: shouldSkipReconciliation),
                context: phaseContext
            )
            timing.finish(
                reconciliationTimer,
                detail: "labelOutcome=\(reconciliationResult.labelOutcome) \(reconciliationResult.diagnostics.summary)"
            )

            // Don't advance historyId if history collection was truncated - we need to
            // retry from the same point to get remaining pages
            let historyAdvanceTimer = timing.start("historyAdvanceDecision")
            let shouldAdvance: Bool
            if historyResult.wasTruncated {
                log.info("History was truncated - will retry from same point on next sync")
                shouldAdvance = false
            } else {
                shouldAdvance = await failureTracker.shouldAdvanceHistoryId(
                    hadFailures: fetchResult.hasFailures,
                    latestHistoryId: historyResult.latestHistoryId
                )
            }
            timing.finish(historyAdvanceTimer, detail: "advance=\(shouldAdvance)")

            let historyIdToSave = shouldAdvance ? historyResult.latestHistoryId : nil
            if let historyIdToSave {
                await messagePersister.setAccountHistoryId(historyIdToSave, in: context)
            }

            let modifiedConversations = await ModificationTracker.shared.modifiedConversations(in: modificationTransaction)
            let trackedDisplayNameOnlyConversations = await ModificationTracker.shared
                .displayNameOnlyConversations(in: modificationTransaction)
            let displayNameOnlyConversations = trackedDisplayNameOnlyConversations.subtracting(modifiedConversations)
            let affectedConversationIDs = modifiedConversations.union(displayNameOnlyConversations)

            // Keep historyId advancement and rollup updates in the same durable save.
            progressHandler(0.99, "Saving changes...")
            let persistenceTimer = timing.start("conversationUpdatesAndSave")
            let conversationUpdatePhase = self.conversationUpdatePhase
            phaseContext.reportProgress(
                0,
                status: "Updating conversations...",
                phase: conversationUpdatePhase
            )
            let conversationManager = self.conversationManager
            let coreDataStack = self.coreDataStack
            try await Self.finalizePersistence(
                labelReconciliationOutcome: reconciliationResult.labelOutcome,
                save: {
                    try await self.rollupMutationSerializer.performThrowingSyncMutation(
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
                },
                commit: {
                    _ = await ModificationTracker.shared.commitTransaction(modificationTransaction)
                    committedModificationTransaction = true
                    await ModificationTracker.shared.consumeCommittedTransaction(modificationTransaction)
                },
                recordReconciliation: {
                    self.recordReconciliationTime()
                }
            )
            phaseContext.reportProgress(
                1,
                status: "Conversations updated",
                phase: conversationUpdatePhase
            )
            timing.finish(
                persistenceTimer,
                detail: "rollups=\(modifiedConversations.count) names=\(displayNameOnlyConversations.count)"
            )

            // Only update abandoned-message tracking once the recovered messages are
            // durably saved; if the save had failed, the records must stay for retry.
            await failureTracker.recordAbandonedRetryOutcome(
                recoveredIds: abandonedOutcome.recoveredIds,
                goneIds: abandonedOutcome.goneIds,
                failedIds: abandonedOutcome.failedIds
            )

            let cleanupTimer = timing.start("incrementalCleanup")
            await dataCleanupService.runIncrementalCleanup()
            timing.finish(cleanupTimer)
            // Publish only after cleanup has finished mutating the message
            // dataset so observers reconcile against the final sync state.
            NotificationCenter.default.post(name: .syncCompleted, object: nil)
            timing.finishRun(
                outcome: "success newMessages=\(fetchResult.successfulCount) labelRecords=\(historyResult.records.count) warnings=\(fetchResult.hasFailures)"
            )

            return IncrementalSyncResult(
                newMessagesCount: fetchResult.successfulCount,
                labelChangesProcessed: historyResult.records.count,
                hadWarnings: fetchResult.hasFailures
            )

        } catch let error as APIError {
            if !committedModificationTransaction {
                await ModificationTracker.shared.rollbackTransaction(modificationTransaction)
            }
            if case .historyIdExpired = error {
                log.warning("History ID expired, performing recovery sync")
                guard await StaticRemoteConfigProvider.shared.isEnabled(.syncRecoveryEnabled) else {
                    log.warning("History recovery skipped because sync recovery is disabled by remote config")
                    throw error
                }
                let recoveryTimer = timing.start("historyRecovery")
                do {
                    try await performHistoryRecoverySync(progressHandler: progressHandler)
                    timing.finish(recoveryTimer)
                    timing.finishRun(outcome: "historyRecovery warnings=true")
                } catch {
                    timing.finish(recoveryTimer, detail: "failed=true")
                    timing.finishRun(outcome: "failed error=\(error.localizedDescription)")
                    throw error
                }
                return IncrementalSyncResult(newMessagesCount: 0, labelChangesProcessed: 0, hadWarnings: true)
            }
            timing.finishRun(outcome: "failed error=\(error.localizedDescription)")
            throw error
        } catch {
            if !committedModificationTransaction {
                await ModificationTracker.shared.rollbackTransaction(modificationTransaction)
            }
            timing.finishRun(outcome: "failed error=\(error.localizedDescription)")
            throw error
        }
    }

    // MARK: - Abandoned Message Retry

    private struct AbandonedRetryOutcome {
        let recoveredIds: [String]
        let goneIds: [String]
        let failedIds: [String]

        static let empty = AbandonedRetryOutcome(recoveredIds: [], goneIds: [], failedIds: [])
    }

    /// Makes one fetch attempt for messages previously abandoned by the failure
    /// tracker, persisting any that now succeed into the sync context. The returned
    /// outcome must be applied to the failure tracker only after the context is
    /// durably saved.
    private func retryAbandonedMessages(phaseContext: SyncPhaseContext) async -> AbandonedRetryOutcome {
        let ids = await failureTracker.fetchRetryableAbandonedMessageIds()
        guard !ids.isEmpty else { return .empty }

        log.info("Retrying \(ids.count) previously abandoned messages")
        let result = await messageFetcher.fetchAbandonedMessages(ids)

        // A fetched message can still be skipped by the persister (e.g.
        // unprocessable payload), so "recovered" is what the persistence
        // report says actually reached the context — otherwise the tracking
        // record would be deleted with no Message row to show for it. An
        // excluded message (moved to spam/trash since abandonment) is
        // resolved: nothing local remains to recover. Unprocessable payloads
        // stay failed and age out via the drain's retry cap.
        var report = MessagePersistenceReport.empty
        if !result.fetched.isEmpty {
            do {
                report = try await messagePersister.saveMessages(
                    result.fetched,
                    labelIds: phaseContext.labelIds,
                    myAliases: phaseContext.myAliases,
                    sendAsAliases: phaseContext.sendAsAliases,
                    modificationTransaction: phaseContext.modificationTransaction,
                    in: phaseContext.coreDataContext
                )
            } catch {
                // Run-fatal persistence failure: keep every tracking record.
                Log.error("Abandoned-message retry aborted by persistence failure", category: .sync, error: error)
                return AbandonedRetryOutcome(
                    recoveredIds: [],
                    goneIds: result.goneIds,
                    failedIds: result.failedIds + result.fetched.map { $0.id }
                )
            }
        }

        return AbandonedRetryOutcome(
            recoveredIds: report.persistedIds + report.excludedIds,
            goneIds: result.goneIds,
            failedIds: result.failedIds + report.failedIds + report.unprocessableIds
        )
    }

    // MARK: - History Recovery

    /// Performs recovery sync when history ID has expired
    private func performHistoryRecoverySync(
        progressHandler: @escaping (Double, String) -> Void
    ) async throws {
        log.info("Starting history recovery sync")

        let context = coreDataStack.newBackgroundContext()
        let modificationTransaction = await ModificationTracker.shared.beginTransaction()
        var committedModificationTransaction = false
        let labelIds = await messagePersister.prefetchLabelIds(in: context)

        let query = SyncTimeCalculator.buildSyncQuery(config: .historyRecovery)

        log.info("Recovery query: \(query)")

        progressHandler(0.1, "Recovering missed messages...")

        do {
            let result = try await MessageListPaginator.fetchAndProcess(
                query: query,
                messageFetcher: messageFetcher
            ) { checkpoint in
                let progress = 0.1 + Self.streamingRecoveryProgressFraction(for: checkpoint) * 0.7
                await MainActor.run {
                    progressHandler(
                        progress,
                        "Recovering... \(checkpoint.processedCount)/\(checkpoint.listedCount)"
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
                // and their derived state persist together (mirrors initial sync); an
                // interrupted recovery keeps every saved page fully presentable.
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

            log.info(
                "Recovery: processed=\(result.totalProcessed), success=\(result.successfulCount), failed=\(result.blockingFailureIds.count)"
            )

            if result.hasFailures {
                await failureTracker.recordFailure(failedIds: result.blockingFailureIds)
            }

            // Get current historyId from Gmail profile and only advance when failure policy allows it.
            // This prevents data loss when recovery fetched only a partial set of messages.
            let profile = try await messageFetcher.getProfile()
            let shouldAdvanceHistoryId = await failureTracker.shouldAdvanceHistoryId(
                hadFailures: result.hasFailures,
                latestHistoryId: profile.historyId
            )
            if shouldAdvanceHistoryId {
                await messagePersister.setAccountHistoryId(profile.historyId, in: context)
            } else {
                log.warning("Recovery had fetch failures - keeping previous historyId to retry safely")
            }

            let modifiedConversations = await ModificationTracker.shared.modifiedConversations(in: modificationTransaction)
            let trackedDisplayNameOnlyConversations = await ModificationTracker.shared
                .displayNameOnlyConversations(in: modificationTransaction)
            let displayNameOnlyConversations = trackedDisplayNameOnlyConversations.subtracting(modifiedConversations)
            let affectedConversationIDs = modifiedConversations.union(displayNameOnlyConversations)

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
            _ = await ModificationTracker.shared.commitTransaction(modificationTransaction)
            committedModificationTransaction = true
            await ModificationTracker.shared.consumeCommittedTransaction(modificationTransaction)

            if shouldAdvanceHistoryId {
                log.info("History recovery complete, new historyId: \(profile.historyId)")
            } else {
                log.info("History recovery complete with warnings; historyId not advanced")
            }
        } catch {
            if !committedModificationTransaction {
                await ModificationTracker.shared.rollbackTransaction(modificationTransaction)
            }
            throw error
        }
    }

    nonisolated private static func streamingRecoveryProgressFraction(for checkpoint: PagedSyncCheckpoint) -> Double {
        let denominator = checkpoint.isComplete
            ? max(checkpoint.listedCount, 1)
            : max(checkpoint.listedCount + SyncConfig.maxMessagesPerRequest, 1)
        let progress = Double(checkpoint.processedCount) / Double(denominator)
        return min(checkpoint.isComplete ? 1.0 : 0.98, progress)
    }

    /// Decides whether to skip label reconciliation for this sync.
    ///
    /// Label reconciliation is the largest steady-state API consumer (one
    /// list call plus one metadata GET per recent message, up to ~100), so it
    /// runs on a TTL rather than on every push-triggered sync:
    /// - never reconciled: run
    /// - history reported changes: run only when `ttl` has lapsed
    /// - quiet sync (no history changes): run only on the hourly force
    ///   interval that catches label drift without history churn
    nonisolated static func shouldSkipLabelReconciliation(
        noHistoryChanges: Bool,
        lastReconciliation: TimeInterval,
        now: TimeInterval,
        ttl: TimeInterval = SyncConfig.labelReconciliationTTL,
        forceInterval: TimeInterval = SyncConfig.reconciliationInterval
    ) -> Bool {
        guard lastReconciliation > 0 else { return false }
        let elapsed = now - lastReconciliation
        let requiredInterval = noHistoryChanges ? forceInterval : ttl
        return elapsed < requiredInterval
    }

    static func finalizePersistence(
        labelReconciliationOutcome: LabelReconciliationOutcome,
        save: () async throws -> Void,
        commit: () async throws -> Void,
        recordReconciliation: () -> Void
    ) async throws {
        try Task.checkCancellation()
        try await save()
        try await commit()
        try Task.checkCancellation()

        if labelReconciliationOutcome == .completed {
            recordReconciliation()
        }
    }

    private func refreshSendAsAliases(
        accountEmail: String,
        in context: NSManagedObjectContext
    ) async -> [SendAsAlias] {
        guard aliasRefreshPolicy.shouldRefresh(accountEmail: accountEmail) else {
            // Inside the TTL: skip the network call but still hydrate the
            // in-memory managers, which are otherwise only populated on the
            // network path. The persisted aliases come from the last
            // successful refresh (initial sync populates them via saveAccount).
            let cachedAliases = await SendAsAliasManager.shared.getAliases(from: context)
            if !cachedAliases.isEmpty {
                _ = await AliasManager.shared.setAliases(
                    Set([accountEmail] + cachedAliases.map(\.emailAddress))
                )
            }
            return cachedAliases
        }

        do {
            let aliases = SendAsAlias.validAliases(
                from: try await messageFetcher.listSendAs(),
                accountEmail: accountEmail
            )
            await messagePersister.updateSendAsAliases(
                accountEmail: accountEmail,
                sendAsAliases: aliases,
                in: context
            )
            await SendAsAliasManager.shared.setAliases(aliases)
            _ = await AliasManager.shared.setAliases(Set([accountEmail] + aliases.map(\.emailAddress)))
            aliasRefreshPolicy.recordSuccessfulRefresh(accountEmail: accountEmail)
            return aliases
        } catch {
            Log.warning("Failed to refresh send-as aliases; using cached aliases: \(error.localizedDescription)", category: .sync)
            return await SendAsAliasManager.shared.getAliases(from: context)
        }
    }

    /// Records the current time as the last reconciliation time
    private func recordReconciliationTime() {
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: SyncConfig.lastReconciliationTimeKey)
    }

    nonisolated static func allowsIntermediateContextSaves(for records: [HistoryRecord]) -> Bool {
        !records.contains { record in
            if let messagesDeleted = record.messagesDeleted, !messagesDeleted.isEmpty {
                return true
            }

            if let messagesAdded = record.messagesAdded,
               messagesAdded.contains(where: { $0.message.labelIds == nil }) {
                return true
            }

            if let labelsAdded = record.labelsAdded,
               labelsAdded.contains(where: { item in
                   item.labelIds.contains(where: MessagePersister.excludedMailboxLabelIDs.contains)
               }) {
                return true
            }

            return false
        }
    }

    nonisolated static func shouldFlushUIVisibleChanges(
        afterLabelProcessingFor records: [HistoryRecord]
    ) -> Bool {
        allowsIntermediateContextSaves(for: records)
    }

}
