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
    private let log = LogCategory.sync.logger

    private var myAliases: Set<String> = []

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
        failureTracker: SyncFailureTracker = .shared
    ) {
        self.messageFetcher = messageFetcher
        self.messagePersister = messagePersister
        self.historyProcessor = historyProcessor
        self.conversationManager = conversationManager
        self.dataCleanupService = dataCleanupService
        self.reconciliation = reconciliation
        self.coreDataStack = coreDataStack
        self.failureTracker = failureTracker
    }

    // MARK: - Public API

    /// Performs incremental sync using composable phases
    func performSync(
        progressHandler: @escaping (Double, String) -> Void,
        initialSyncFallback: @escaping () async throws -> Void
    ) async throws -> IncrementalSyncResult {
        let syncStartTime = Date()

        // Fetch account data
        let accountData = try await messagePersister.fetchAccountData()

        guard let accountData = accountData, let historyId = accountData.historyId else {
            log.info("No account/historyId found, performing initial sync")
            try await initialSyncFallback()
            return IncrementalSyncResult(newMessagesCount: 0, labelChangesProcessed: 0, hadWarnings: false)
        }

        log.info("Starting incremental sync with historyId: \(historyId)")
        myAliases = await AliasManager.shared.getAliases(from: coreDataStack.newBackgroundContext())

        let context = coreDataStack.newBackgroundContext()
        let modificationTransaction = await ModificationTracker.shared.beginTransaction()
        var committedModificationTransaction = false
        let labelIds = await messagePersister.prefetchLabelIds(in: context)

        // Create shared context for all phases
        let phaseContext = SyncPhaseContext(
            coreDataContext: context,
            labelIds: labelIds,
            myAliases: myAliases,
            modificationTransaction: modificationTransaction,
            syncStartTime: syncStartTime,
            progressHandler: progressHandler,
            failureTracker: failureTracker
        )

        do {
            // Phase 1: Collect all history
            let historyResult = try await historyCollectionPhase.execute(
                input: historyId,
                context: phaseContext
            )

            // Phase 2: Fetch new messages
            let fetchResult = try await messageFetchPhase.execute(
                input: historyResult.newMessageIds,
                context: phaseContext
            )

            // Phase 3: Process label changes (AFTER messages are fetched)
            try await labelProcessingPhase.execute(
                input: historyResult.records,
                context: phaseContext
            )
            if Self.shouldFlushUIVisibleChanges(afterLabelProcessingFor: historyResult.records) {
                try await flushUIVisibleChangesIfNeeded(
                    in: context,
                    stageDescription: "label processing"
                )
            } else {
                log.debug("Deferring mid-sync flush because history includes destructive local changes")
            }

            // Phase 4: Reconciliation
            // Skip label reconciliation when history reported no changes (saves ~2.5s per sync)
            // BUT run reconciliation periodically (every hour) to catch label drift
            let noHistoryChanges = historyResult.records.isEmpty && historyResult.newMessageIds.isEmpty
            let shouldSkipReconciliation = noHistoryChanges && !shouldForceReconciliation()
            try await reconciliationPhase.execute(
                input: ReconciliationInput(skipLabelReconciliation: shouldSkipReconciliation),
                context: phaseContext
            )
            if !shouldSkipReconciliation {
                recordReconciliationTime()
            }

            // Don't advance historyId if history collection was truncated - we need to
            // retry from the same point to get remaining pages
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

            let historyIdToSave = shouldAdvance ? historyResult.latestHistoryId : nil
            if let historyIdToSave {
                await messagePersister.setAccountHistoryId(historyIdToSave, in: context)
            }

            let modifiedConversations = await ModificationTracker.shared.modifiedConversations(in: modificationTransaction)

            // Keep historyId advancement and rollup updates in the same durable save.
            try await conversationUpdatePhase.execute(
                input: modifiedConversations,
                context: phaseContext
            )
            progressHandler(0.99, "Saving changes...")
            try await coreDataStack.saveAsync(context: context)
            _ = await ModificationTracker.shared.commitTransaction(modificationTransaction)
            committedModificationTransaction = true
            await ModificationTracker.shared.consumeCommittedTransaction(modificationTransaction)

            NotificationCenter.default.post(name: .syncCompleted, object: nil)
            await dataCleanupService.runIncrementalCleanup()

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
                try await performHistoryRecoverySync(progressHandler: progressHandler)
                return IncrementalSyncResult(newMessagesCount: 0, labelChangesProcessed: 0, hadWarnings: true)
            }
            throw error
        } catch {
            if !committedModificationTransaction {
                await ModificationTracker.shared.rollbackTransaction(modificationTransaction)
            }
            throw error
        }
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
            // Collect all message IDs using shared paginator
            let allMessageIds = try await MessageListPaginator.fetchAllMessageIds(
                query: query,
                using: messageFetcher
            )

            // Fetch messages
            let result = try await BatchProcessor.processMessages(
                messageIds: allMessageIds,
                batchSize: SyncConfig.messageBatchSize,
                messageFetcher: messageFetcher
            ) { processed, total in
                let progress = 0.1 + (Double(processed) / Double(max(total, 1))) * 0.7
                await MainActor.run {
                    progressHandler(progress, "Recovering... \(processed)/\(total)")
                }
            } messageHandler: { [messagePersister, myAliases] message in
                // Capture dependencies strongly to prevent message loss if orchestrator is deallocated
                await messagePersister.saveMessage(
                    message,
                    labelIds: labelIds,
                    myAliases: myAliases,
                    modificationTransaction: modificationTransaction,
                    in: context
                )
            }

            log.info(
                "Recovery: processed=\(result.totalProcessed), success=\(result.successfulCount), failed=\(result.failedIds.count)"
            )

            if result.hasFailures {
                await failureTracker.recordFailure(failedIds: result.failedIds)
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

            if !modifiedConversations.isEmpty {
                await conversationManager.updateRollupsForModifiedConversations(
                    conversationIDs: modifiedConversations,
                    in: context
                )
            }

            try await coreDataStack.saveAsync(context: context)
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

    /// Checks if forced label reconciliation is needed based on time since last reconciliation
    private func shouldForceReconciliation() -> Bool {
        let defaults = UserDefaults.standard
        let lastReconciliation = defaults.double(forKey: SyncConfig.lastReconciliationTimeKey)

        // Force reconciliation if we've never done one or it's been too long
        guard lastReconciliation > 0 else { return true }

        let timeSinceLastReconciliation = Date().timeIntervalSince1970 - lastReconciliation
        return timeSinceLastReconciliation >= SyncConfig.reconciliationInterval
    }

    /// Records the current time as the last reconciliation time
    private func recordReconciliationTime() {
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: SyncConfig.lastReconciliationTimeKey)
    }

    nonisolated static func shouldFlushUIVisibleChanges(
        afterLabelProcessingFor records: [HistoryRecord]
    ) -> Bool {
        !records.contains { record in
            if let messagesDeleted = record.messagesDeleted, !messagesDeleted.isEmpty {
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

    /// Saves the sync context mid-run so conversation list updates (preview/unread) merge
    /// into the view context immediately instead of waiting for final historyId persistence.
    private func flushUIVisibleChangesIfNeeded(
        in context: NSManagedObjectContext,
        stageDescription: String
    ) async throws {
        try await context.perform {
            guard context.hasChanges else { return }
            try context.save()
        }
        log.debug("Flushed sync changes after \(stageDescription)")
    }
}
