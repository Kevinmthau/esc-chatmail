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
    private let log = LogCategory.sync.logger

    private var myAliases: Set<String> = []

    // MARK: - Initialization

    init(
        messageFetcher: MessageFetcher,
        messagePersister: MessagePersister,
        conversationManager: ConversationManager,
        dataCleanupService: DataCleanupService,
        attachmentDownloader: AttachmentDownloader,
        coreDataStack: CoreDataStack,
        failureTracker: SyncFailureTracker = .shared,
        performanceLogger: CoreDataPerformanceLogger = .shared
    ) {
        self.messageFetcher = messageFetcher
        self.messagePersister = messagePersister
        self.conversationManager = conversationManager
        self.dataCleanupService = dataCleanupService
        self.attachmentDownloader = attachmentDownloader
        self.coreDataStack = coreDataStack
        self.failureTracker = failureTracker
        self.performanceLogger = performanceLogger
    }

    // MARK: - Public API

    /// Performs initial full sync
    /// - Parameter progressHandler: Callback for progress updates
    /// - Returns: Result of the sync operation
    func performSync(
        progressHandler: @escaping (Double, String) -> Void
    ) async throws -> InitialSyncResult {
        let syncStartTime = CFAbsoluteTimeGetCurrent()
        let signpostID = performanceLogger.beginOperation("InitialSync")

        let context = coreDataStack.newBackgroundContext()
        let modificationTransaction = await ModificationTracker.shared.beginTransaction()
        var committedModificationTransaction = false

        // Run one-time cleanup
        await runInitialCleanupIfNeeded(in: context)

        do {
            // Phase 1: Fetch profile and aliases
            progressHandler(0.05, "Fetching profile...")
            let (profile, aliases) = try await fetchProfileAndAliases()
            myAliases = Set(([profile.emailAddress] + aliases).map(normalizedEmail))
            await AliasManager.shared.setAliases(myAliases)
            try await messagePersister.saveAccount(
                profile: profile,
                aliases: aliases,
                in: context,
                saveHistoryId: false
            )

            // Phase 2: Fetch and save labels
            progressHandler(0.1, "Fetching labels...")
            let labels = try await messageFetcher.listLabels()
            await messagePersister.saveLabels(labels, in: context)
            let labelIds = await messagePersister.prefetchLabelIds(in: context)

            // Phase 3: Fetch and process messages
            progressHandler(0.2, "Fetching messages...")
            let query = buildInitialSyncQuery()
            log.info("Initial sync query: \(query)")

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

            log.info("Initial sync: processed=\(result.totalProcessed), success=\(result.successfulCount), failed=\(result.failedIds.count)")

            // Phase 4: Handle failures and determine historyId advancement
            let syncCompletedWithWarnings = await handleSyncCompletion(
                result: result,
                profile: profile,
                labelIds: labelIds,
                modificationTransaction: modificationTransaction,
                context: context
            )

            // Phase 5: Keep historyId and rollup updates in the same save so later syncs
            // never advance past message changes without the derived conversation state.
            let modifiedConversations = await ModificationTracker.shared.modifiedConversations(in: modificationTransaction)
            let trackedDisplayNameOnlyConversations = await ModificationTracker.shared
                .displayNameOnlyConversations(in: modificationTransaction)
            let displayNameOnlyConversations = trackedDisplayNameOnlyConversations.subtracting(modifiedConversations)

            progressHandler(0.85, "Updating conversations...")
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

            progressHandler(0.95, "Saving changes...")
            try await coreDataStack.saveAsync(context: context)
            log.info("Initial sync save successful")

            _ = await ModificationTracker.shared.commitTransaction(modificationTransaction)
            committedModificationTransaction = true
            await ModificationTracker.shared.consumeCommittedTransaction(modificationTransaction)

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

    private func fetchProfileAndAliases() async throws -> (GmailProfile, [String]) {
        let profile = try await messageFetcher.getProfile()
        let sendAsList = try await messageFetcher.listSendAs()
        let aliases = sendAsList
            .filter { $0.treatAsAlias == true || $0.isPrimary == true }
            .map { $0.sendAsEmail }
        return (profile, aliases)
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
        // Collect all message IDs using shared paginator
        let allMessageIds = try await MessageListPaginator.fetchAllMessageIds(
            query: query,
            using: messageFetcher
        )

        log.info("Found \(allMessageIds.count) messages to process")

        // Process in batches
        return try await BatchProcessor.processMessages(
            messageIds: allMessageIds,
            batchSize: SyncConfig.messageBatchSize,
            messageFetcher: messageFetcher
        ) { processed, total in
            let progress = Double(processed) / Double(max(total, 1))
            await MainActor.run {
                progressHandler(progress, "Processing messages... \(processed)/\(total)")
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
    }

    func handleSyncCompletion(
        result: BatchProcessingResult,
        profile: GmailProfile,
        labelIds: Set<String>,
        modificationTransaction: ModificationTracker.Transaction,
        context: NSManagedObjectContext
    ) async -> Bool {
        var syncCompletedWithWarnings = false

        if result.hasFailures {
            log.warning("Initial sync has \(result.failedIds.count) failed messages")
            syncCompletedWithWarnings = true

            // Retry failed messages
            let stillFailedIds = await BatchProcessor.retryFailedMessages(
                failedIds: result.failedIds,
                messageFetcher: messageFetcher
            ) { [messagePersister, myAliases] message in
                // Capture dependencies strongly to prevent message loss if orchestrator is deallocated
                await messagePersister.saveMessage(
                    message,
                    labelIds: labelIds,
                    myAliases: myAliases,
                    modificationTransaction: modificationTransaction,
                    in: context
                )
            }

            let disposition = Self.completionDisposition(
                hadInitialFailures: true,
                permanentlyFailedCount: stillFailedIds.count
            )
            if disposition.shouldAdvanceHistoryId {
                await messagePersister.setAccountHistoryId(profile.historyId, in: context)
            }

            if disposition.hadWarnings {
                log.warning("\(stillFailedIds.count) messages permanently failed - keeping historyId unset so initial sync can retry safely")
                await failureTracker.recordFailure(failedIds: stillFailedIds)
            } else {
                log.info("All failed messages recovered on retry - advancing historyId")
                await failureTracker.recordSuccess()
            }
            syncCompletedWithWarnings = disposition.hadWarnings
        } else {
            log.info("All messages fetched successfully - advancing historyId to \(profile.historyId)")
            await messagePersister.setAccountHistoryId(profile.historyId, in: context)
            await failureTracker.recordSuccess()
        }

        return syncCompletedWithWarnings
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
