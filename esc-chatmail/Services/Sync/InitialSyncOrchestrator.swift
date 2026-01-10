import Foundation
import CoreData

/// Result of initial sync operation
struct InitialSyncResult {
    let messagesProcessed: Int
    let conversationCount: Int
    let duration: TimeInterval
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

        // Run one-time cleanup
        await runInitialCleanupIfNeeded(in: context)

        do {
            // Phase 1: Fetch profile and aliases
            progressHandler(0.05, "Fetching profile...")
            let (profile, aliases) = try await fetchProfileAndAliases()
            myAliases = Set(([profile.emailAddress] + aliases).map(normalizedEmail))
            _ = await messagePersister.saveAccount(profile: profile, aliases: aliases, in: context)

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
                context: context,
                progressHandler: { progress, status in
                    // Map 0-1 to 0.2-0.85
                    progressHandler(0.2 + progress * 0.65, status)
                }
            )

            log.info("Initial sync: processed=\(result.totalProcessed), success=\(result.successfulCount), failed=\(result.failedIds.count)")

            // Phase 4: Update conversation rollups (only for modified conversations)
            progressHandler(0.85, "Updating conversations...")
            let modifiedConversations = await messagePersister.getAndClearModifiedConversations()
            if !modifiedConversations.isEmpty {
                await conversationManager.updateRollupsForModifiedConversations(
                    conversationIDs: modifiedConversations,
                    in: context
                )
            }
            let conversationCount = await countConversations(in: context)

            // Phase 5: Handle failures and determine historyId advancement
            let syncCompletedWithWarnings = await handleSyncCompletion(
                result: result,
                profile: profile,
                labelIds: labelIds,
                context: context
            )

            // Phase 6: Save everything
            progressHandler(0.95, "Saving changes...")
            try await coreDataStack.saveAsync(context: context)
            log.info("Initial sync save successful")

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
            performanceLogger.endOperation("InitialSync", signpostID: signpostID)
            log.error("Initial sync failed", error: error)
            throw error
        }
    }

    /// Returns the user's email aliases
    func getMyAliases() -> Set<String> {
        myAliases
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
            // Use install timestamp minus 5-minute buffer
            let cutoffTimestamp = Int(installTimestamp) - 300
            log.info("Fetching messages after install time: \(Date(timeIntervalSince1970: installTimestamp))")
            return "after:\(cutoffTimestamp) -label:spam -label:drafts"
        } else {
            // Fallback: 30 days
            let thirtyDaysAgo = Int(Date().timeIntervalSince1970) - (30 * 24 * 60 * 60)
            log.warning("No install timestamp found, using 30-day fallback")
            return "after:\(thirtyDaysAgo) -label:spam -label:drafts"
        }
    }

    private func fetchAndProcessMessages(
        query: String,
        labelIds: Set<String>,
        context: NSManagedObjectContext,
        progressHandler: @escaping (Double, String) -> Void
    ) async throws -> BatchProcessingResult {
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
        } messageHandler: { [weak self] message in
            guard let self = self else { return }
            await self.messagePersister.saveMessage(
                message,
                labelIds: labelIds,
                myAliases: self.myAliases,
                in: context
            )
        }
    }

    private func handleSyncCompletion(
        result: BatchProcessingResult,
        profile: GmailProfile,
        labelIds: Set<String>,
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
            ) { [weak self] message in
                guard let self = self else { return }
                await self.messagePersister.saveMessage(
                    message,
                    labelIds: labelIds,
                    myAliases: self.myAliases,
                    in: context
                )
            }

            if stillFailedIds.isEmpty {
                log.info("All failed messages recovered on retry - advancing historyId")
                await messagePersister.setAccountHistoryId(profile.historyId, in: context)
                syncCompletedWithWarnings = false
            } else {
                log.warning("\(stillFailedIds.count) messages permanently failed - NOT advancing historyId")
                await failureTracker.recordFailure(failedIds: stillFailedIds)
            }
        } else {
            log.info("All messages fetched successfully - advancing historyId to \(profile.historyId)")
            await messagePersister.setAccountHistoryId(profile.historyId, in: context)
            await failureTracker.recordSuccess()
        }

        return syncCompletedWithWarnings
    }

    private func countConversations(in context: NSManagedObjectContext) async -> Int {
        await context.perform {
            let request = Conversation.fetchRequest()
            return (try? context.count(for: request)) ?? 0
        }
    }
}
