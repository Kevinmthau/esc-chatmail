import Foundation
import CoreData
import Combine

extension Notification.Name {
    static let syncCompleted = Notification.Name("com.esc.inboxchat.syncCompleted")
}

// MARK: - Sync Engine

/// Orchestrates email synchronization between Gmail API and local Core Data storage
///
/// Responsibilities:
/// - Coordinates initial and incremental sync workflows
/// - Manages sync state and UI updates
/// - Delegates to specialized services for:
///   - Message fetching (MessageFetcher)
///   - Message persistence (MessagePersister)
///   - History processing (HistoryProcessor)
///   - Data cleanup (DataCleanupService)
@MainActor
final class SyncEngine: ObservableObject {
    static let shared = SyncEngine()

    /// Published UI state - use this for UI bindings
    @Published private(set) var uiState = SyncUIState()

    // Convenience accessors for backward compatibility
    var isSyncing: Bool { uiState.isSyncing }
    var syncProgress: Double { uiState.syncProgress }
    var syncStatus: String { uiState.syncStatus }

    // MARK: - Dependencies

    private let messageFetcher: MessageFetcher
    private let messagePersister: MessagePersister
    private let historyProcessor: HistoryProcessor
    private let dataCleanupService: DataCleanupService
    private let conversationManager: ConversationManager
    private let coreDataStack: CoreDataStack
    private let attachmentDownloader: AttachmentDownloader
    private let performanceLogger: CoreDataPerformanceLogger
    private let networkMonitor: NetworkMonitorService
    private let syncStateActor: SyncStateActor

    private var myAliases: Set<String> = []
    private var cancellables = Set<AnyCancellable>()

    // MARK: - Initialization

    private init() {
        self.messageFetcher = MessageFetcher()
        self.messagePersister = MessagePersister()
        self.historyProcessor = HistoryProcessor()
        self.dataCleanupService = DataCleanupService()
        self.conversationManager = ConversationManager()
        self.coreDataStack = .shared
        self.attachmentDownloader = .shared
        self.performanceLogger = .shared
        self.networkMonitor = NetworkMonitorService()
        self.syncStateActor = SyncStateActor()
    }

    deinit {
        cancellables.forEach { $0.cancel() }
        cancellables.removeAll()
    }

    // MARK: - Public API

    /// Cancels any currently running sync operation
    func cancelSync() async {
        print("Cancelling sync...")
        await syncStateActor.cancelCurrentSync()
        uiState.update(isSyncing: false, status: "Sync cancelled")
    }

    /// Performs initial full sync
    func performInitialSync() async throws {
        guard await syncStateActor.beginSync() else {
            print("Sync already in progress, skipping initial sync")
            return
        }

        let syncTask = Task {
            try await performInitialSyncLogic()
        }

        await syncStateActor.setSyncTask(syncTask)

        do {
            try await syncTask.value
            await syncStateActor.endSync()
        } catch is CancellationError {
            await syncStateActor.endSync()
            print("Initial sync was cancelled")
            uiState.update(isSyncing: false, status: "Sync cancelled")
        } catch {
            await syncStateActor.endSync()
            print("Initial sync failed: \(error)")
            uiState.update(isSyncing: false, status: "Sync failed: \(error.localizedDescription)")
        }
    }

    /// Performs incremental sync using Gmail history API
    func performIncrementalSync() async throws {
        guard await syncStateActor.beginSync() else {
            print("Sync already in progress, skipping incremental sync")
            return
        }

        guard await networkMonitor.isNetworkAvailable() else {
            await syncStateActor.endSync()
            print("Network not available, skipping sync")
            uiState.update(isSyncing: false, status: "Network unavailable")
            return
        }

        let syncTask = Task { [weak self] () -> Void in
            guard let self = self else { return }
            try await self.performIncrementalSyncLogic()
        }

        await syncStateActor.setSyncTask(syncTask)

        do {
            try await syncTask.value
            await syncStateActor.endSync()
        } catch is CancellationError {
            await syncStateActor.endSync()
            print("Incremental sync was cancelled")
            uiState.update(isSyncing: false, status: "Sync cancelled")
        } catch {
            await syncStateActor.endSync()
            print("Incremental sync failed: \(error)")
            uiState.update(isSyncing: false, status: "Sync failed: \(error.localizedDescription)")
        }
    }

    /// Clears local modifications for synced messages
    func clearLocalModifications(for messageIds: [String]) async {
        await historyProcessor.clearLocalModifications(for: messageIds)
    }

    /// Updates conversation rollups
    nonisolated func updateConversationRollups(in context: NSManagedObjectContext) async {
        await conversationManager.updateAllConversationRollups(in: context)
    }

    /// Prefetches labels for background sync
    nonisolated func prefetchLabelsForBackground(in context: NSManagedObjectContext) async -> [String: Label] {
        return await messagePersister.prefetchLabels(in: context)
    }

    /// Saves a message (used by BackgroundSyncManager)
    func saveMessage(_ gmailMessage: GmailMessage, labelCache: [String: Label]? = nil, in context: NSManagedObjectContext) async {
        await messagePersister.saveMessage(
            gmailMessage,
            labelCache: labelCache,
            myAliases: myAliases,
            in: context
        )
    }

    // MARK: - Initial Sync Logic

    private func performInitialSyncLogic() async throws {
        let syncStartTime = CFAbsoluteTimeGetCurrent()
        let signpostID = performanceLogger.beginOperation("InitialSync")

        uiState.update(isSyncing: true, progress: 0.0, status: "Starting sync...")

        let context = coreDataStack.newBackgroundContext()

        // Run duplicate cleanup once per install
        let hasDoneCleanup = UserDefaults.standard.bool(forKey: "hasDoneDuplicateCleanupV1")
        if !hasDoneCleanup {
            await dataCleanupService.runFullCleanup(in: context)
            UserDefaults.standard.set(true, forKey: "hasDoneDuplicateCleanupV1")
        }

        do {
            // Fetch profile and aliases
            let profile = try await messageFetcher.getProfile()
            let sendAsList = try await messageFetcher.listSendAs()
            let aliases = sendAsList
                .filter { $0.treatAsAlias == true || $0.isPrimary == true }
                .map { $0.sendAsEmail }

            myAliases = Set(([profile.emailAddress] + aliases).map(normalizedEmail))

            _ = await messagePersister.saveAccount(profile: profile, aliases: aliases, in: context)

            uiState.update(progress: 0.1, status: "Fetching labels...")

            // Fetch and save labels
            let labels = try await messageFetcher.listLabels()
            await messagePersister.saveLabels(labels, in: context)

            let labelCache = await messagePersister.prefetchLabels(in: context)

            uiState.update(progress: 0.2, status: "Fetching messages...")

            // Build query for messages from install time forward (excluding spam and drafts)
            // This ensures we only sync messages that arrived after the user installed the app
            let installTimestamp = UserDefaults.standard.double(forKey: "installTimestamp")
            let gmailQuery: String

            if installTimestamp > 0 {
                // Use install timestamp as cutoff - only sync messages after install
                // Subtract 5 minutes buffer to catch any messages in-flight during install
                let cutoffTimestamp = Int(installTimestamp) - 300
                gmailQuery = "after:\(cutoffTimestamp) -label:spam -label:drafts"
                let now = Date().timeIntervalSince1970
                let ageMinutes = (now - installTimestamp) / 60
                print("🔄 INITIAL SYNC - Fetching messages after install time")
                print("📅 Install timestamp: \(installTimestamp) (\(Date(timeIntervalSince1970: installTimestamp)))")
                print("📅 Cutoff timestamp: \(cutoffTimestamp) (install - 5min buffer)")
                print("📅 Install was \(String(format: "%.1f", ageMinutes)) minutes ago")
            } else {
                // Fallback: no install timestamp found, use current time minus 30 days
                // This shouldn't happen in normal operation but provides a safeguard
                let thirtyDaysAgo = Int(Date().timeIntervalSince1970) - (30 * 24 * 60 * 60)
                gmailQuery = "after:\(thirtyDaysAgo) -label:spam -label:drafts"
                print("⚠️ [SyncCorrectness] No install timestamp found, using 30-day fallback")
            }

            print("🔍 Gmail query: \(gmailQuery)")

            // Stream process messages in batches
            uiState.update(progress: 0.3, status: "Fetching messages...")

            // Note: labelCache contains NSManagedObjects which aren't Sendable, but we ensure
            // all Core Data operations happen on the same background context
            nonisolated(unsafe) let unsafeLabelCache = labelCache
            let result = try await fetchAndProcessAllMessages(
                query: gmailQuery,
                labelCache: unsafeLabelCache,
                context: context,
                baseProgress: 0.3,
                maxProgress: 0.9
            )

            print("📊 [SyncCorrectness] Initial sync totals: processed=\(result.totalProcessed), successful=\(result.successfulCount), failed=\(result.failedIds.count)")
            uiState.update(progress: 0.9, status: "Processed \(result.successfulCount) messages")

            // Update conversation rollups
            let rollupStartTime = CFAbsoluteTimeGetCurrent()
            await conversationManager.updateAllConversationRollups(in: context)
            let rollupDuration = CFAbsoluteTimeGetCurrent() - rollupStartTime

            let conversationCount = await countConversations(in: context)

            // Determine if we should advance historyId
            var syncCompletedWithWarnings = false

            // Only set historyId in the context if ALL messages were fetched successfully
            // This ensures historyId is saved transactionally with messages
            if result.hasFailures {
                print("⚠️ [SyncCorrectness] Initial sync has \(result.failedIds.count) failed messages - NOT advancing historyId")
                print("⚠️ [SyncCorrectness] Failed message IDs: \(result.failedIds.prefix(10))...")
                syncCompletedWithWarnings = true

                // Retry failed messages
                let stillFailedIds = await BatchProcessor.retryFailedMessages(
                    failedIds: result.failedIds,
                    messageFetcher: messageFetcher
                ) { [weak self] message in
                    guard let self = self else { return }
                    await self.messagePersister.saveMessage(
                        message,
                        labelCache: unsafeLabelCache,
                        myAliases: self.myAliases,
                        in: context
                    )
                }

                if stillFailedIds.isEmpty {
                    print("✅ [SyncCorrectness] All failed messages recovered on retry - advancing historyId")
                    await messagePersister.setAccountHistoryId(profile.historyId, in: context)
                    syncCompletedWithWarnings = false
                } else {
                    print("⚠️ [SyncCorrectness] \(stillFailedIds.count) messages permanently failed - NOT advancing historyId")
                }
            } else {
                print("✅ [SyncCorrectness] All messages fetched successfully - advancing historyId to \(profile.historyId)")
                await messagePersister.setAccountHistoryId(profile.historyId, in: context)
            }

            // Save changes (use async to avoid blocking main thread)
            // historyId is now part of this save transaction
            let saveStartTime = CFAbsoluteTimeGetCurrent()
            do {
                try await coreDataStack.saveAsync(context: context)
                let saveDuration = CFAbsoluteTimeGetCurrent() - saveStartTime
                performanceLogger.logSave(insertions: result.successfulCount, updates: 0, deletions: 0, duration: saveDuration)
                print("✅ [SyncCorrectness] Initial sync save successful - historyId persisted in same transaction")

                // Record successful sync time so incremental sync reconciliation uses correct window
                UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: SyncConfig.lastSuccessfulSyncTimeKey)
            } catch {
                print("❌ [SyncCorrectness] Failed to save sync data - historyId NOT advanced: \(error)")
                throw error
            }

            // Start downloading attachments
            Task {
                await attachmentDownloader.enqueueAllPendingAttachments()
            }

            // Log summary
            let totalDuration = CFAbsoluteTimeGetCurrent() - syncStartTime
            performanceLogger.endOperation("InitialSync", signpostID: signpostID)
            performanceLogger.logSyncSummary(
                messagesProcessed: result.successfulCount,
                conversationsUpdated: conversationCount,
                totalDuration: totalDuration
            )

            #if DEBUG
            print("📊 Conversation rollup took \(String(format: "%.2f", rollupDuration))s")
            #endif

            let finalStatus = syncCompletedWithWarnings ? "Sync completed with warnings" : "Sync complete"
            uiState.update(isSyncing: false, progress: 1.0, status: finalStatus)

        } catch {
            performanceLogger.endOperation("InitialSync", signpostID: signpostID)
            uiState.update(isSyncing: false, status: "Sync failed: \(error.localizedDescription)")
            throw error
        }
    }

    // MARK: - Incremental Sync Logic

    private func performIncrementalSyncLogic() async throws {
        let syncStartTime = Date()

        // Fetch account data
        let accountData = try await messagePersister.fetchAccountData()

        if accountData == nil || accountData?.historyId == nil {
            print("No account/historyId found, performing initial sync")
            try await performInitialSyncLogic()
            return
        }

        let historyId = accountData!.historyId!
        let email = accountData!.email
        let aliases = accountData!.aliases

        print("Starting incremental sync with historyId: \(historyId)")

        myAliases = Set(([email] + aliases).map(normalizedEmail))

        uiState.update(isSyncing: true, progress: 0.0, status: "Checking for updates...")

        let context = coreDataStack.newBackgroundContext()
        let labelCache = await messagePersister.prefetchLabels(in: context)

        do {
            var pageToken: String? = nil
            var latestHistoryId = historyId
            var allNewMessageIds: [String] = []
            var allHistoryRecords: [HistoryRecord] = []

            uiState.update(progress: 0.1, status: "Fetching history...")

            // Collect all history records first (don't process yet)
            repeat {
                try Task.checkCancellation()

                let (history, newHistoryId, nextPageToken) = try await messageFetcher.listHistory(
                    startHistoryId: historyId,
                    pageToken: pageToken
                )

                if let history = history, !history.isEmpty {
                    print("📬 Received \(history.count) history records")

                    // Extract new message IDs
                    let newIds = historyProcessor.extractNewMessageIds(from: history)
                    allNewMessageIds.append(contentsOf: newIds)

                    // Collect history records for deferred processing
                    // IMPORTANT: Process label changes AFTER fetching new messages to avoid race conditions
                    // where a message is added and immediately archived but we process the archive before the message exists
                    allHistoryRecords.append(contentsOf: history)
                } else {
                    print("📭 No history changes from Gmail API (historyId: \(historyId))")
                }

                if let newHistoryId = newHistoryId {
                    print("📝 New history ID from API: \(newHistoryId)")
                    latestHistoryId = newHistoryId
                }

                pageToken = nextPageToken
            } while pageToken != nil

            try Task.checkCancellation()

            // Note: labelCache contains NSManagedObjects which aren't Sendable, but we ensure
            // all Core Data operations happen on the same background context
            nonisolated(unsafe) let unsafeLabelCache = labelCache

            // Fetch new messages using BatchProcessor
            var fetchFailed = false
            if !allNewMessageIds.isEmpty {
                print("📊 [SyncCorrectness] Incremental sync: \(allNewMessageIds.count) new message IDs to fetch")
                uiState.update(progress: 0.3, status: "Fetching \(allNewMessageIds.count) new messages...")

                let result = try await BatchProcessor.processMessages(
                    messageIds: allNewMessageIds,
                    batchSize: SyncConfig.messageBatchSize,
                    messageFetcher: messageFetcher
                ) { [weak self] processed, total in
                    guard let self = self else { return }
                    let progress = 0.3 + (Double(processed) / Double(total)) * 0.5
                    await MainActor.run {
                        self.uiState.update(
                            progress: progress,
                            status: "Processing messages... \(processed)/\(total)"
                        )
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

                print("📊 [SyncCorrectness] Incremental sync totals: requested=\(allNewMessageIds.count), success=\(result.successfulCount), failed=\(result.failedIds.count)")

                if result.hasFailures {
                    print("⚠️ [SyncCorrectness] \(result.failedIds.count) messages failed to fetch, will retry on next sync")
                    print("⚠️ [SyncCorrectness] Failed IDs: \(result.failedIds.prefix(10))...")
                    fetchFailed = true
                    // Track failed IDs for persistence across sync attempts
                    trackFailedMessageIds(result.failedIds)
                }
            } else {
                print("📊 [SyncCorrectness] Incremental sync: no new messages to fetch")
            }

            // NOW process lightweight operations (label changes, deletions) AFTER new messages are fetched
            // This ensures that if a message is added and immediately has labels changed,
            // the message exists locally before we try to update its labels
            if !allHistoryRecords.isEmpty {
                print("🏷️ [SyncCorrectness] Processing \(allHistoryRecords.count) history records for label changes...")
                for record in allHistoryRecords {
                    await historyProcessor.processLightweightOperations(
                        record,
                        in: context,
                        syncStartTime: syncStartTime
                    )
                }
            }

            // Reconciliation: Check for any missed messages from the last hour
            uiState.update(progress: 0.8, status: "Checking for missed messages...")
            try Task.checkCancellation()

            print("🔄 [SyncCorrectness] Running reconciliation check for missed messages...")
            let missedIds = await checkForMissedMessages(in: context)
            if !missedIds.isEmpty {
                print("🔍 [SyncCorrectness] Reconciliation found \(missedIds.count) messages in Gmail but not locally")
                print("🔍 [SyncCorrectness] Missed IDs: \(missedIds.prefix(10))...")

                let failedMissedIds = await BatchProcessor.retryFailedMessages(
                    failedIds: missedIds,
                    messageFetcher: messageFetcher
                ) { [weak self] message in
                    guard let self = self else { return }
                    await self.messagePersister.saveMessage(
                        message,
                        labelCache: unsafeLabelCache,
                        myAliases: self.myAliases,
                        in: context
                    )
                }

                let successCount = missedIds.count - failedMissedIds.count
                print("📊 [SyncCorrectness] Reconciliation fetch: requested=\(missedIds.count), success=\(successCount), failed=\(failedMissedIds.count)")

                if !failedMissedIds.isEmpty {
                    print("⚠️ [SyncCorrectness] Failed to fetch \(failedMissedIds.count) missed messages")
                }
            } else {
                print("✅ [SyncCorrectness] Reconciliation: no missed messages found")
            }

            // Reconcile label states for recent messages to catch missed archive/label changes
            uiState.update(progress: 0.83, status: "Verifying label states...")
            await reconcileLabelStates(in: context, labelCache: unsafeLabelCache)

            uiState.update(progress: 0.85, status: "Updating conversations...")

            try Task.checkCancellation()

            // Update rollups only for modified conversations (much more efficient than updateAll)
            // Include both message persister changes (new messages) and history processor changes (label updates)
            var modifiedConversationIDs = messagePersister.getAndClearModifiedConversations()
            let historyModifiedIDs = historyProcessor.getAndClearModifiedConversations()
            modifiedConversationIDs.formUnion(historyModifiedIDs)

            if !modifiedConversationIDs.isEmpty {
                await conversationManager.updateRollupsForModifiedConversations(
                    conversationIDs: modifiedConversationIDs,
                    in: context
                )
            }
            await dataCleanupService.runIncrementalCleanup(in: context)

            uiState.update(progress: 0.95, status: "Saving changes...")

            // Determine whether to advance historyId based on failure tracking
            let shouldAdvanceHistoryId = await determineShouldAdvanceHistoryId(
                fetchFailed: fetchFailed,
                latestHistoryId: latestHistoryId
            )

            if shouldAdvanceHistoryId {
                print("✅ [SyncCorrectness] Incremental sync - advancing historyId to \(latestHistoryId)")
                await messagePersister.setAccountHistoryId(latestHistoryId, in: context)
            } else {
                print("⚠️ [SyncCorrectness] Incremental sync has fetch failures - NOT advancing historyId")
            }

            // Save changes - historyId is now part of this save transaction
            do {
                try await coreDataStack.saveAsync(context: context)
                if !fetchFailed {
                    print("✅ [SyncCorrectness] Incremental sync save successful - historyId \(latestHistoryId) persisted in same transaction")
                } else {
                    print("✅ [SyncCorrectness] Incremental sync save successful - historyId NOT advanced due to fetch failures")
                }
            } catch {
                print("❌ [SyncCorrectness] Failed to save incremental sync - historyId NOT advanced: \(error)")
                throw error
            }

            uiState.update(isSyncing: false, progress: 1.0, status: fetchFailed ? "Sync completed with warnings" : "Sync complete")

            NotificationCenter.default.post(name: .syncCompleted, object: nil)

        } catch {
            if error is CancellationError {
                throw error
            } else if let apiError = error as? APIError, case .historyIdExpired = apiError {
                print("History ID expired, performing recovery sync")
                try await performHistoryRecoverySync()
            } else {
                let errorMessage = formatSyncError(error)
                uiState.update(isSyncing: false, status: "Sync failed: \(errorMessage)")
                // Re-throw all errors so callers can handle them appropriately
                throw error
            }
        }
    }

    /// Performs a recovery sync when history ID has expired
    /// Uses the last successful sync time to minimize data loss
    private func performHistoryRecoverySync() async throws {
        print("🔄 [SyncCorrectness] Starting history recovery sync...")

        let context = coreDataStack.newBackgroundContext()
        let labelCache = await messagePersister.prefetchLabels(in: context)

        // Determine the recovery time window
        let defaults = UserDefaults.standard
        let lastSuccessfulSync = defaults.double(forKey: SyncConfig.lastSuccessfulSyncTimeKey)

        let recoveryStartTime: TimeInterval
        if lastSuccessfulSync > 0 {
            // Use last successful sync time minus a 10-minute buffer for safety
            recoveryStartTime = lastSuccessfulSync - 600
            let syncDate = Date(timeIntervalSince1970: lastSuccessfulSync)
            print("🔄 [SyncCorrectness] Recovery from last sync: \(syncDate)")
        } else {
            // No last sync time, use install timestamp or 7 days as fallback
            let installTimestamp = defaults.double(forKey: "installTimestamp")
            if installTimestamp > 0 {
                recoveryStartTime = installTimestamp - 300
                print("🔄 [SyncCorrectness] Recovery from install time (no last sync recorded)")
            } else {
                // Ultimate fallback: 7 days ago
                recoveryStartTime = Date().timeIntervalSince1970 - (7 * 24 * 60 * 60)
                print("⚠️ [SyncCorrectness] No timestamps available, recovering last 7 days")
            }
        }

        // Build query for messages since recovery time
        let gmailQuery = "after:\(Int(recoveryStartTime)) -label:spam -label:drafts"
        print("🔍 [SyncCorrectness] Recovery query: \(gmailQuery)")

        uiState.update(isSyncing: true, progress: 0.1, status: "Recovering missed messages...")

        // Fetch and process messages
        nonisolated(unsafe) let unsafeLabelCache = labelCache
        let result = try await fetchAndProcessAllMessages(
            query: gmailQuery,
            labelCache: unsafeLabelCache,
            context: context,
            baseProgress: 0.1,
            maxProgress: 0.8
        )

        print("📊 [SyncCorrectness] Recovery sync: processed=\(result.totalProcessed), success=\(result.successfulCount), failed=\(result.failedIds.count)")

        // Update conversation rollups
        await conversationManager.updateAllConversationRollups(in: context)

        // Get new profile for historyId
        let profile = try await messageFetcher.getProfile()
        await messagePersister.setAccountHistoryId(profile.historyId, in: context)

        // Save changes
        try await coreDataStack.saveAsync(context: context)

        // Update tracking
        defaults.set(Date().timeIntervalSince1970, forKey: SyncConfig.lastSuccessfulSyncTimeKey)
        defaults.set(0, forKey: SyncConfig.consecutiveFailuresKey)

        print("✅ [SyncCorrectness] History recovery complete, new historyId: \(profile.historyId)")
        uiState.update(isSyncing: false, progress: 1.0, status: "Recovery complete")
    }

    // MARK: - Reconciliation

    /// Reconciles label states for recent messages to catch missed label changes (like archiving)
    /// This is especially important for detecting archive actions that might have been missed
    private func reconcileLabelStates(in context: NSManagedObjectContext, labelCache: [String: Label]) async {
        do {
            // Fetch a sample of recent messages to verify their label states
            let twoHoursAgo = Date().addingTimeInterval(-7200)
            let epochSeconds = Int(twoHoursAgo.timeIntervalSince1970)
            let query = "after:\(epochSeconds) -label:spam -label:drafts"

            // Get message IDs from Gmail
            let (recentMessageIds, _) = try await messageFetcher.listMessages(
                query: query,
                maxResults: 30  // Sample of recent messages
            )

            guard !recentMessageIds.isEmpty else {
                print("✅ [SyncCorrectness] No recent messages to reconcile labels for")
                return
            }

            print("🏷️ [SyncCorrectness] Reconciling labels for \(recentMessageIds.count) recent messages...")

            var labelMismatches = 0
            var updatedMessages = 0

            // Note: labelCache contains NSManagedObjects which aren't Sendable, but we ensure
            // all Core Data operations happen on the same background context
            nonisolated(unsafe) let unsafeLabelCache = labelCache

            // Fetch full message details from Gmail and compare with local
            for messageId in recentMessageIds {
                do {
                    // Fetch the message from Gmail
                    let gmailMessage = try await GmailAPIClient.shared.getMessage(id: messageId, format: "metadata")

                    // Check local message
                    await context.perform {
                        let request = Message.fetchRequest()
                        request.predicate = NSPredicate(format: "id == %@", messageId)
                        request.fetchLimit = 1

                        guard let localMessage = try? context.fetch(request).first else {
                            return // Message not in local DB
                        }

                        // Skip if message has pending local changes
                        if let localModifiedAt = localMessage.value(forKey: "localModifiedAt") as? Date,
                           localModifiedAt > Date().addingTimeInterval(-300) { // Modified in last 5 minutes
                            return
                        }

                        // Get Gmail label IDs
                        let gmailLabelIds = Set(gmailMessage.labelIds ?? [])

                        // Get local label IDs
                        let localLabels = localMessage.labels ?? []
                        let localLabelIds = Set(localLabels.compactMap { $0.id })

                        // Check for INBOX label discrepancy (most important for archive detection)
                        let gmailHasInbox = gmailLabelIds.contains("INBOX")
                        let localHasInbox = localLabelIds.contains("INBOX")

                        if gmailHasInbox != localHasInbox {
                            labelMismatches += 1
                            print("🔧 [SyncCorrectness] Label mismatch for \(messageId): Gmail INBOX=\(gmailHasInbox), local INBOX=\(localHasInbox)")

                            // Update local message to match Gmail
                            if gmailHasInbox {
                                // Add INBOX label
                                if let inboxLabel = unsafeLabelCache["INBOX"] {
                                    localMessage.addToLabels(inboxLabel)
                                }
                            } else {
                                // Remove INBOX label
                                if let inboxLabel = localLabels.first(where: { $0.id == "INBOX" }) {
                                    localMessage.removeFromLabels(inboxLabel)
                                }
                            }

                            // Track conversation for rollup update
                            if let conversation = localMessage.conversation {
                                self.historyProcessor.trackModifiedConversationForReconciliation(conversation)
                            }

                            updatedMessages += 1
                        }

                        // Check UNREAD status
                        let gmailIsUnread = gmailLabelIds.contains("UNREAD")
                        if localMessage.isUnread != gmailIsUnread {
                            localMessage.isUnread = gmailIsUnread
                            if let conversation = localMessage.conversation {
                                self.historyProcessor.trackModifiedConversationForReconciliation(conversation)
                            }
                        }
                    }
                } catch {
                    // Skip messages that fail to fetch (might be deleted)
                    continue
                }
            }

            if labelMismatches > 0 {
                print("🔧 [SyncCorrectness] Label reconciliation: found \(labelMismatches) mismatches, updated \(updatedMessages) messages")
            } else {
                print("✅ [SyncCorrectness] Label reconciliation: no mismatches found")
            }
        } catch {
            print("⚠️ [SyncCorrectness] Label reconciliation failed: \(error.localizedDescription)")
        }
    }

    /// Checks for messages that might have been missed by the history sync
    /// Returns message IDs that exist in Gmail but not locally
    private func checkForMissedMessages(in context: NSManagedObjectContext) async -> [String] {
        do {
            // Use the last successful sync time as the reconciliation window
            // This ensures we catch messages that arrived while we were offline
            let defaults = UserDefaults.standard
            let lastSuccessfulSync = defaults.double(forKey: SyncConfig.lastSuccessfulSyncTimeKey)

            let reconciliationStartTime: Date
            if lastSuccessfulSync > 0 {
                // Use last successful sync time, but add a 5-minute buffer for safety
                let syncDate = Date(timeIntervalSince1970: lastSuccessfulSync)
                reconciliationStartTime = syncDate.addingTimeInterval(-300) // 5 minute buffer

                let timeSinceLastSync = Date().timeIntervalSince(syncDate)
                print("🔄 [SyncCorrectness] Reconciliation window: since last sync (\(Int(timeSinceLastSync / 60)) minutes ago)")
            } else {
                // Fallback to 1 hour if no last sync time recorded
                reconciliationStartTime = Date().addingTimeInterval(-3600)
                print("🔄 [SyncCorrectness] Reconciliation window: last 1 hour (no previous sync time)")
            }

            // Cap the reconciliation window to 24 hours to avoid fetching too many messages
            let maxReconciliationTime = Date().addingTimeInterval(-86400) // 24 hours

            // CRITICAL: Never reconcile messages from before the install timestamp
            // This prevents fetching old messages that weren't included in initial sync
            let installTimestamp = defaults.double(forKey: "installTimestamp")
            let installCutoff = installTimestamp > 0 ? Date(timeIntervalSince1970: installTimestamp - 300) : Date.distantPast

            let effectiveStartTime = max(reconciliationStartTime, maxReconciliationTime, installCutoff)
            let epochSeconds = Int(effectiveStartTime.timeIntervalSince1970)

            print("🔄 [SyncCorrectness] Effective reconciliation cutoff: \(Date(timeIntervalSince1970: TimeInterval(epochSeconds)))")

            let query = "after:\(epochSeconds) -label:spam -label:drafts"

            // Increase max results for longer offline periods
            let timeSinceStart = Date().timeIntervalSince(effectiveStartTime)
            let maxResults = min(200, max(50, Int(timeSinceStart / 3600) * 20)) // 20 per hour, capped at 200

            let (recentMessageIds, _) = try await messageFetcher.listMessages(
                query: query,
                maxResults: maxResults
            )

            guard !recentMessageIds.isEmpty else {
                return []
            }

            print("🔍 [SyncCorrectness] Checking \(recentMessageIds.count) recent Gmail messages against local DB")

            // Check which of these we don't have locally
            let missingIds = await context.perform {
                var missing: [String] = []
                for messageId in recentMessageIds {
                    let request = Message.fetchRequest()
                    request.predicate = NSPredicate(format: "id == %@", messageId)
                    request.fetchLimit = 1

                    if let count = try? context.count(for: request), count == 0 {
                        missing.append(messageId)
                    }
                }
                return missing
            }

            if !missingIds.isEmpty {
                print("📭 Reconciliation found \(missingIds.count) messages in Gmail but not locally")
            }

            return missingIds
        } catch {
            print("⚠️ Reconciliation check failed: \(error.localizedDescription)")
            return []
        }
    }

    // MARK: - Batch Processing Helpers

    /// Fetches all messages matching the query and processes them in batches
    private func fetchAndProcessAllMessages(
        query: String,
        labelCache: [String: Label],
        context: NSManagedObjectContext,
        baseProgress: Double,
        maxProgress: Double
    ) async throws -> BatchProcessingResult {
        var pageToken: String? = nil
        var allMessageIds: [String] = []

        // First, collect all message IDs across pages
        repeat {
            try Task.checkCancellation()

            let (messageIds, nextPageToken) = try await messageFetcher.listMessages(
                query: query,
                pageToken: pageToken
            )

            print("📋 Full sync page: \(messageIds.count) message IDs returned")
            allMessageIds.append(contentsOf: messageIds)
            pageToken = nextPageToken
        } while pageToken != nil

        // Now process all IDs using BatchProcessor
        return try await BatchProcessor.processMessages(
            messageIds: allMessageIds,
            batchSize: SyncConfig.messageBatchSize,
            messageFetcher: messageFetcher
        ) { [weak self] processed, total in
            guard let self = self else { return }
            let progress = baseProgress + (Double(processed) / Double(max(total, 1))) * (maxProgress - baseProgress)
            await MainActor.run {
                self.uiState.update(
                    progress: min(maxProgress, progress),
                    status: "Processing messages... \(processed)"
                )
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
    }

    // MARK: - Failure Tracking

    /// Determines whether to advance historyId based on failure tracking
    /// - Parameters:
    ///   - fetchFailed: Whether any messages failed to fetch in the current sync
    ///   - latestHistoryId: The new historyId to potentially advance to
    /// - Returns: true if historyId should be advanced
    private func determineShouldAdvanceHistoryId(fetchFailed: Bool, latestHistoryId: String) async -> Bool {
        let defaults = UserDefaults.standard

        if !fetchFailed {
            // Success - reset failure tracking and record successful sync time
            defaults.set(0, forKey: SyncConfig.consecutiveFailuresKey)
            defaults.removeObject(forKey: SyncConfig.persistentFailedIdsKey)
            defaults.set(Date().timeIntervalSince1970, forKey: SyncConfig.lastSuccessfulSyncTimeKey)
            print("✅ [SyncCorrectness] All messages fetched successfully - resetting failure tracking")
            return true
        }

        // Fetch failed - increment failure counter
        let consecutiveFailures = defaults.integer(forKey: SyncConfig.consecutiveFailuresKey) + 1
        defaults.set(consecutiveFailures, forKey: SyncConfig.consecutiveFailuresKey)

        print("⚠️ [SyncCorrectness] Consecutive sync failures: \(consecutiveFailures)/\(SyncConfig.maxConsecutiveSyncFailures)")

        // Check if we've exceeded the maximum consecutive failures
        if consecutiveFailures >= SyncConfig.maxConsecutiveSyncFailures {
            print("🚨 [SyncCorrectness] Maximum consecutive failures reached (\(consecutiveFailures))")
            print("🚨 [SyncCorrectness] Advancing historyId anyway to prevent sync deadlock")

            // Log the abandoned messages for debugging
            if let persistentFailedIds = defaults.stringArray(forKey: SyncConfig.persistentFailedIdsKey) {
                print("🚨 [SyncCorrectness] Abandoning \(persistentFailedIds.count) unfetchable messages: \(persistentFailedIds)")
            }

            // Reset tracking since we're moving forward
            defaults.set(0, forKey: SyncConfig.consecutiveFailuresKey)
            defaults.removeObject(forKey: SyncConfig.persistentFailedIdsKey)
            defaults.set(Date().timeIntervalSince1970, forKey: SyncConfig.lastSuccessfulSyncTimeKey)

            return true
        }

        return false
    }

    /// Tracks failed message IDs for persistence across sync attempts
    func trackFailedMessageIds(_ failedIds: [String]) {
        guard !failedIds.isEmpty else { return }

        let defaults = UserDefaults.standard
        var persistentIds = defaults.stringArray(forKey: SyncConfig.persistentFailedIdsKey) ?? []

        // Add new failed IDs (avoid duplicates)
        let existingSet = Set(persistentIds)
        let newIds = failedIds.filter { !existingSet.contains($0) }
        persistentIds.append(contentsOf: newIds)

        // Limit the size to prevent unbounded growth
        if persistentIds.count > SyncConfig.maxFailedMessagesBeforeAdvance * 2 {
            persistentIds = Array(persistentIds.suffix(SyncConfig.maxFailedMessagesBeforeAdvance))
        }

        defaults.set(persistentIds, forKey: SyncConfig.persistentFailedIdsKey)
        print("📝 [SyncCorrectness] Tracking \(persistentIds.count) persistent failed message IDs")
    }

    // MARK: - Helpers

    private func countConversations(in context: NSManagedObjectContext) async -> Int {
        return await context.perform {
            let request = NSFetchRequest<NSNumber>(entityName: "Conversation")
            request.resultType = .countResultType
            return (try? context.fetch(request).first?.intValue) ?? 0
        }
    }

    private func formatSyncError(_ error: Error) -> String {
        if let apiError = error as? APIError {
            switch apiError {
            case .historyIdExpired:
                return "History expired, re-syncing..."
            case .authenticationError:
                return "Authentication failed"
            case .rateLimited:
                return "Rate limited, please try again later"
            case .timeout:
                return "Request timed out"
            case .networkError(let underlying):
                return "Network error: \(underlying.localizedDescription)"
            case .serverError(let code):
                return "Server error: \(code)"
            default:
                return apiError.localizedDescription
            }
        } else if let urlError = error as? URLError {
            switch urlError.code {
            case .unsupportedURL:
                return "Invalid URL configuration"
            case .notConnectedToInternet:
                return "No internet connection"
            case .timedOut:
                return "Request timed out"
            case .networkConnectionLost:
                return "Network connection lost"
            default:
                return "Network error: \(urlError.localizedDescription)"
            }
        }
        return error.localizedDescription
    }
}
