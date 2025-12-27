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
/// Responsibilities:
/// - Fetch history changes since last sync
/// - Process new messages and label changes
/// - Run reconciliation to catch missed changes
/// - Handle history ID expiration with recovery sync
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

    /// Performs incremental sync
    /// - Parameters:
    ///   - progressHandler: Callback for progress updates
    ///   - initialSyncFallback: Closure to call if initial sync is needed
    /// - Returns: Result of the sync operation
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
        myAliases = Set(([accountData.email] + accountData.aliases).map(normalizedEmail))

        let context = coreDataStack.newBackgroundContext()
        let labelCache = await messagePersister.prefetchLabels(in: context)

        do {
            // Phase 1: Collect all history
            progressHandler(0.1, "Fetching history...")
            let historyResult = try await collectHistory(startHistoryId: historyId)

            // Phase 2: Fetch new messages
            progressHandler(0.3, "Fetching new messages...")
            nonisolated(unsafe) let unsafeLabelCache = labelCache
            let fetchResult = try await fetchNewMessages(
                messageIds: historyResult.newMessageIds,
                labelCache: unsafeLabelCache,
                context: context,
                progressHandler: { progress, status in
                    progressHandler(0.3 + progress * 0.4, status)
                }
            )

            // Phase 3: Process label changes (AFTER messages are fetched)
            progressHandler(0.7, "Processing label changes...")
            await processHistoryRecords(
                records: historyResult.records,
                context: context,
                syncStartTime: syncStartTime
            )

            // Phase 4: Reconciliation
            progressHandler(0.8, "Checking for missed messages...")
            try Task.checkCancellation()
            await runReconciliation(context: context, labelCache: unsafeLabelCache)

            // Phase 5: Update rollups
            progressHandler(0.85, "Updating conversations...")
            await updateModifiedConversations(context: context)
            await dataCleanupService.runIncrementalCleanup(in: context)

            // Phase 6: Save
            progressHandler(0.95, "Saving changes...")
            let shouldAdvance = failureTracker.shouldAdvanceHistoryId(
                hadFailures: fetchResult.hasFailures,
                latestHistoryId: historyResult.latestHistoryId
            )

            if shouldAdvance {
                await messagePersister.setAccountHistoryId(historyResult.latestHistoryId, in: context)
            }

            try await coreDataStack.saveAsync(context: context)

            NotificationCenter.default.post(name: .syncCompleted, object: nil)

            return IncrementalSyncResult(
                newMessagesCount: fetchResult.successfulCount,
                labelChangesProcessed: historyResult.records.count,
                hadWarnings: fetchResult.hasFailures
            )

        } catch let error as APIError {
            if case .historyIdExpired = error {
                log.warning("History ID expired, performing recovery sync")
                try await performHistoryRecoverySync(progressHandler: progressHandler)
                return IncrementalSyncResult(newMessagesCount: 0, labelChangesProcessed: 0, hadWarnings: true)
            }
            throw error
        }
    }

    /// Sets the user's email aliases (called from SyncEngine)
    func setMyAliases(_ aliases: Set<String>) {
        myAliases = aliases
    }

    // MARK: - History Collection

    private struct HistoryCollectionResult {
        let newMessageIds: [String]
        let records: [HistoryRecord]
        let latestHistoryId: String
    }

    private func collectHistory(startHistoryId: String) async throws -> HistoryCollectionResult {
        var pageToken: String? = nil
        var latestHistoryId = startHistoryId
        var allNewMessageIds: [String] = []
        var allHistoryRecords: [HistoryRecord] = []

        repeat {
            try Task.checkCancellation()

            let (history, newHistoryId, nextPageToken) = try await messageFetcher.listHistory(
                startHistoryId: startHistoryId,
                pageToken: pageToken
            )

            if let history = history, !history.isEmpty {
                log.debug("Received \(history.count) history records")
                let newIds = historyProcessor.extractNewMessageIds(from: history)
                allNewMessageIds.append(contentsOf: newIds)
                allHistoryRecords.append(contentsOf: history)
            }

            if let newHistoryId = newHistoryId {
                latestHistoryId = newHistoryId
            }

            pageToken = nextPageToken
        } while pageToken != nil

        log.info("History collection: \(allNewMessageIds.count) new messages, \(allHistoryRecords.count) records")

        return HistoryCollectionResult(
            newMessageIds: allNewMessageIds,
            records: allHistoryRecords,
            latestHistoryId: latestHistoryId
        )
    }

    // MARK: - Message Fetching

    private func fetchNewMessages(
        messageIds: [String],
        labelCache: [String: Label],
        context: NSManagedObjectContext,
        progressHandler: @escaping (Double, String) -> Void
    ) async throws -> BatchProcessingResult {
        guard !messageIds.isEmpty else {
            log.debug("No new messages to fetch")
            return BatchProcessingResult(totalProcessed: 0, successfulCount: 0, failedIds: [])
        }

        log.info("Fetching \(messageIds.count) new messages")

        let result = try await BatchProcessor.processMessages(
            messageIds: messageIds,
            batchSize: SyncConfig.messageBatchSize,
            messageFetcher: messageFetcher
        ) { processed, total in
            let progress = Double(processed) / Double(total)
            await MainActor.run {
                progressHandler(progress, "Processing messages... \(processed)/\(total)")
            }
        } messageHandler: { [weak self] message in
            guard let self = self else { return }
            await self.messagePersister.saveMessage(
                message,
                labelCache: labelCache,
                myAliases: self.myAliases,
                in: context
            )
        }

        if result.hasFailures {
            log.warning("\(result.failedIds.count) messages failed to fetch")
            failureTracker.recordFailure(failedIds: result.failedIds)
        }

        return result
    }

    // MARK: - History Processing

    private func processHistoryRecords(
        records: [HistoryRecord],
        context: NSManagedObjectContext,
        syncStartTime: Date
    ) async {
        guard !records.isEmpty else { return }

        log.debug("Processing \(records.count) history records for label changes")

        for record in records {
            await historyProcessor.processLightweightOperations(
                record,
                in: context,
                syncStartTime: syncStartTime
            )
        }
    }

    // MARK: - Reconciliation

    private func runReconciliation(
        context: NSManagedObjectContext,
        labelCache: [String: Label]
    ) async {
        let installTimestamp = UserDefaults.standard.double(forKey: "installTimestamp")

        // Check for missed messages
        let missedIds = await reconciliation.checkForMissedMessages(
            in: context,
            installTimestamp: installTimestamp
        )

        if !missedIds.isEmpty {
            log.info("Reconciliation found \(missedIds.count) missed messages")

            let failedMissedIds = await BatchProcessor.retryFailedMessages(
                failedIds: missedIds,
                messageFetcher: messageFetcher
            ) { [weak self] message in
                guard let self = self else { return }
                await self.messagePersister.saveMessage(
                    message,
                    labelCache: labelCache,
                    myAliases: self.myAliases,
                    in: context
                )
            }

            if !failedMissedIds.isEmpty {
                log.warning("Failed to fetch \(failedMissedIds.count) missed messages")
            }
        }

        // Reconcile labels
        await reconciliation.reconcileLabelStates(in: context, labelCache: labelCache)
    }

    // MARK: - Conversation Updates

    private func updateModifiedConversations(context: NSManagedObjectContext) async {
        var modifiedIDs = messagePersister.getAndClearModifiedConversations()
        let historyModifiedIDs = historyProcessor.getAndClearModifiedConversations()
        modifiedIDs.formUnion(historyModifiedIDs)

        log.debug("Updating rollups for \(modifiedIDs.count) modified conversations")

        if !modifiedIDs.isEmpty {
            await conversationManager.updateRollupsForModifiedConversations(
                conversationIDs: modifiedIDs,
                in: context
            )
        }
    }

    // MARK: - History Recovery

    /// Performs recovery sync when history ID has expired
    private func performHistoryRecoverySync(
        progressHandler: @escaping (Double, String) -> Void
    ) async throws {
        log.info("Starting history recovery sync")

        let context = coreDataStack.newBackgroundContext()
        let labelCache = await messagePersister.prefetchLabels(in: context)

        let recoveryStartTime = calculateRecoveryStartTime()
        let query = "after:\(Int(recoveryStartTime)) -label:spam -label:drafts"

        log.info("Recovery query: \(query)")

        progressHandler(0.1, "Recovering missed messages...")

        // Collect all message IDs
        var pageToken: String? = nil
        var allMessageIds: [String] = []

        repeat {
            try Task.checkCancellation()
            let (messageIds, nextPageToken) = try await messageFetcher.listMessages(
                query: query,
                pageToken: pageToken
            )
            allMessageIds.append(contentsOf: messageIds)
            pageToken = nextPageToken
        } while pageToken != nil

        // Fetch messages
        nonisolated(unsafe) let unsafeLabelCache = labelCache
        let result = try await BatchProcessor.processMessages(
            messageIds: allMessageIds,
            batchSize: SyncConfig.messageBatchSize,
            messageFetcher: messageFetcher
        ) { processed, total in
            let progress = 0.1 + (Double(processed) / Double(max(total, 1))) * 0.7
            await MainActor.run {
                progressHandler(progress, "Recovering... \(processed)/\(total)")
            }
        } messageHandler: { [weak self] message in
            guard let self = self else { return }
            await self.messagePersister.saveMessage(
                message,
                labelCache: unsafeLabelCache,
                myAliases: self.myAliases,
                in: context
            )
        }

        log.info("Recovery: processed=\(result.totalProcessed), success=\(result.successfulCount)")

        // Update rollups
        await conversationManager.updateAllConversationRollups(in: context)

        // Get new historyId
        let profile = try await messageFetcher.getProfile()
        await messagePersister.setAccountHistoryId(profile.historyId, in: context)

        // Save
        try await coreDataStack.saveAsync(context: context)

        // Reset tracking
        failureTracker.recordSuccess()

        log.info("History recovery complete, new historyId: \(profile.historyId)")
    }

    private func calculateRecoveryStartTime() -> TimeInterval {
        let defaults = UserDefaults.standard
        let lastSuccessfulSync = defaults.double(forKey: SyncConfig.lastSuccessfulSyncTimeKey)

        if lastSuccessfulSync > 0 {
            // Last sync minus 10-minute buffer
            return lastSuccessfulSync - 600
        }

        let installTimestamp = defaults.double(forKey: "installTimestamp")
        if installTimestamp > 0 {
            return installTimestamp - 300
        }

        // Ultimate fallback: 7 days ago
        return Date().timeIntervalSince1970 - (7 * 24 * 60 * 60)
    }
}
