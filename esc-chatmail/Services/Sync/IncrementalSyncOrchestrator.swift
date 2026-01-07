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
        conversationManager: conversationManager,
        dataCleanupService: dataCleanupService,
        messagePersister: messagePersister,
        historyProcessor: historyProcessor
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
        myAliases = Set(([accountData.email] + accountData.aliases).map(normalizedEmail))

        let context = coreDataStack.newBackgroundContext()
        let labelIds = await messagePersister.prefetchLabelIds(in: context)

        // Create shared context for all phases
        let phaseContext = SyncPhaseContext(
            coreDataContext: context,
            labelIds: labelIds,
            myAliases: myAliases,
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

            // Phase 4: Reconciliation
            // Skip label reconciliation when history reported no changes (saves ~2.5s per sync)
            let noHistoryChanges = historyResult.records.isEmpty && historyResult.newMessageIds.isEmpty
            try await reconciliationPhase.execute(
                input: ReconciliationInput(skipLabelReconciliation: noHistoryChanges),
                context: phaseContext
            )

            // Phase 5: Update rollups
            try await conversationUpdatePhase.execute(
                input: (),
                context: phaseContext
            )

            // Phase 6: Save
            progressHandler(0.95, "Saving changes...")
            let shouldAdvance = await failureTracker.shouldAdvanceHistoryId(
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

    // MARK: - History Recovery

    /// Performs recovery sync when history ID has expired
    private func performHistoryRecoverySync(
        progressHandler: @escaping (Double, String) -> Void
    ) async throws {
        log.info("Starting history recovery sync")

        let context = coreDataStack.newBackgroundContext()
        let labelIds = await messagePersister.prefetchLabelIds(in: context)

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
                labelIds: labelIds,
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
        await failureTracker.recordSuccess()

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
