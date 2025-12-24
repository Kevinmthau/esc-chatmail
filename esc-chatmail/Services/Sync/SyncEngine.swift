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
            var pageToken: String? = nil
            var totalProcessed = 0
            var totalSuccessfullyFetched = 0
            var allFailedIds: [String] = []

            uiState.update(progress: 0.3, status: "Fetching messages...")

            repeat {
                try Task.checkCancellation()

                let (messageIds, nextPageToken) = try await messageFetcher.listMessages(
                    query: gmailQuery,
                    pageToken: pageToken
                )

                print("📋 Full sync page: \(messageIds.count) message IDs returned")

                // Process this page in batches
                // Note: labelCache contains NSManagedObjects which aren't Sendable, but we ensure
                // all Core Data operations happen on the same background context
                nonisolated(unsafe) let unsafeLabelCache = labelCache

                for batch in messageIds.chunked(into: SyncConfig.messageBatchSize) {
                    try Task.checkCancellation()

                    let failedIds = await messageFetcher.fetchBatch(batch) { [weak self] message in
                        guard let self = self else { return }
                        await self.messagePersister.saveMessage(
                            message,
                            labelCache: unsafeLabelCache,
                            myAliases: self.myAliases,
                            in: context
                        )
                    }

                    // Track successful vs failed fetches
                    let successCount = batch.count - failedIds.count
                    totalSuccessfullyFetched += successCount
                    allFailedIds.append(contentsOf: failedIds)
                    totalProcessed += batch.count

                    print("📊 [SyncCorrectness] Batch: requested=\(batch.count), success=\(successCount), failed=\(failedIds.count)")

                    await MainActor.run {
                        self.uiState.update(
                            progress: min(0.9, 0.3 + (Double(totalProcessed) / 10000.0) * 0.6),
                            status: "Processing messages... \(totalProcessed)"
                        )
                    }
                }

                pageToken = nextPageToken
            } while pageToken != nil

            print("📊 [SyncCorrectness] Initial sync totals: processed=\(totalProcessed), successful=\(totalSuccessfullyFetched), failed=\(allFailedIds.count)")
            uiState.update(progress: 0.9, status: "Processed \(totalSuccessfullyFetched) messages")

            // Update conversation rollups
            let rollupStartTime = CFAbsoluteTimeGetCurrent()
            await conversationManager.updateAllConversationRollups(in: context)
            let rollupDuration = CFAbsoluteTimeGetCurrent() - rollupStartTime

            let conversationCount = await countConversations(in: context)

            // Determine if we should advance historyId
            let hasFailures = !allFailedIds.isEmpty
            var syncCompletedWithWarnings = false

            // Only set historyId in the context if ALL messages were fetched successfully
            // This ensures historyId is saved transactionally with messages
            if hasFailures {
                print("⚠️ [SyncCorrectness] Initial sync has \(allFailedIds.count) failed messages - NOT advancing historyId")
                print("⚠️ [SyncCorrectness] Failed message IDs: \(allFailedIds.prefix(10))...")
                syncCompletedWithWarnings = true

                // Run reconciliation for failed IDs specifically
                nonisolated(unsafe) let unsafeLabelCache = labelCache
                print("🔄 [SyncCorrectness] Retrying \(allFailedIds.count) failed messages via reconciliation...")
                let stillFailedIds = await messageFetcher.fetchBatch(allFailedIds) { [weak self] message in
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
                performanceLogger.logSave(insertions: totalSuccessfullyFetched, updates: 0, deletions: 0, duration: saveDuration)
                print("✅ [SyncCorrectness] Initial sync save successful - historyId persisted in same transaction")
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
                messagesProcessed: totalSuccessfullyFetched,
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

            uiState.update(progress: 0.1, status: "Fetching history...")

            // Collect history records
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

                    // Process lightweight operations (label changes, deletions)
                    for record in history {
                        await historyProcessor.processLightweightOperations(
                            record,
                            in: context,
                            syncStartTime: syncStartTime
                        )
                    }
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

            // Fetch new messages
            var fetchFailed = false
            var totalSuccessfullyFetched = 0
            if !allNewMessageIds.isEmpty {
                print("📊 [SyncCorrectness] Incremental sync: \(allNewMessageIds.count) new message IDs to fetch")
                uiState.update(progress: 0.3, status: "Fetching \(allNewMessageIds.count) new messages...")

                // Note: labelCache contains NSManagedObjects which aren't Sendable, but we ensure
                // all Core Data operations happen on the same background context
                nonisolated(unsafe) let unsafeLabelCache = labelCache

                var processedCount = 0
                var totalFailedIds: [String] = []

                for batch in allNewMessageIds.chunked(into: SyncConfig.messageBatchSize) {
                    try Task.checkCancellation()

                    let failedIds = await messageFetcher.fetchBatch(batch) { [weak self] message in
                        guard let self = self else { return }
                        await self.messagePersister.saveMessage(
                            message,
                            labelCache: unsafeLabelCache,
                            myAliases: self.myAliases,
                            in: context
                        )
                    }

                    let successCount = batch.count - failedIds.count
                    totalSuccessfullyFetched += successCount
                    totalFailedIds.append(contentsOf: failedIds)
                    processedCount += batch.count

                    print("📊 [SyncCorrectness] Incremental batch: requested=\(batch.count), success=\(successCount), failed=\(failedIds.count)")

                    let progress = 0.3 + (Double(processedCount) / Double(allNewMessageIds.count)) * 0.5

                    await MainActor.run {
                        self.uiState.update(
                            progress: progress,
                            status: "Processing messages... \(processedCount)/\(allNewMessageIds.count)"
                        )
                    }
                }

                print("📊 [SyncCorrectness] Incremental sync totals: requested=\(allNewMessageIds.count), success=\(totalSuccessfullyFetched), failed=\(totalFailedIds.count)")

                // If any messages failed to fetch, don't update history ID to avoid losing them
                if !totalFailedIds.isEmpty {
                    print("⚠️ [SyncCorrectness] \(totalFailedIds.count) messages failed to fetch, will retry on next sync")
                    print("⚠️ [SyncCorrectness] Failed IDs: \(totalFailedIds.prefix(10))...")
                    fetchFailed = true
                }
            } else {
                print("📊 [SyncCorrectness] Incremental sync: no new messages to fetch")
            }

            // Reconciliation: Check for any missed messages from the last hour
            uiState.update(progress: 0.8, status: "Checking for missed messages...")
            try Task.checkCancellation()

            print("🔄 [SyncCorrectness] Running reconciliation check for missed messages...")
            let missedIds = await checkForMissedMessages(in: context)
            if !missedIds.isEmpty {
                print("🔍 [SyncCorrectness] Reconciliation found \(missedIds.count) messages in Gmail but not locally")
                print("🔍 [SyncCorrectness] Missed IDs: \(missedIds.prefix(10))...")
                nonisolated(unsafe) let unsafeLabelCache = labelCache

                let failedMissedIds = await messageFetcher.fetchBatch(missedIds) { [weak self] message in
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

            uiState.update(progress: 0.85, status: "Updating conversations...")

            try Task.checkCancellation()

            // Update rollups only for modified conversations (much more efficient than updateAll)
            let modifiedConversationIDs = messagePersister.getAndClearModifiedConversations()
            if !modifiedConversationIDs.isEmpty {
                await conversationManager.updateRollupsForModifiedConversations(
                    conversationIDs: modifiedConversationIDs,
                    in: context
                )
            }
            await dataCleanupService.runIncrementalCleanup(in: context)

            uiState.update(progress: 0.95, status: "Saving changes...")

            // Only set historyId in the context if ALL messages were fetched successfully
            // This ensures historyId is saved transactionally with messages
            if !fetchFailed {
                print("✅ [SyncCorrectness] Incremental sync - all messages fetched, setting historyId to \(latestHistoryId) in context")
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
                print("History ID expired, performing full sync")
                try await performInitialSyncLogic()
            } else {
                let errorMessage = formatSyncError(error)
                uiState.update(isSyncing: false, status: "Sync failed: \(errorMessage)")
                // Re-throw all errors so callers can handle them appropriately
                throw error
            }
        }
    }

    // MARK: - Reconciliation

    /// Checks for messages that might have been missed by the history sync
    /// Returns message IDs that exist in Gmail but not locally
    private func checkForMissedMessages(in context: NSManagedObjectContext) async -> [String] {
        do {
            // Query Gmail for recent messages (last hour)
            let oneHourAgo = Date().addingTimeInterval(-3600)
            let epochSeconds = Int(oneHourAgo.timeIntervalSince1970)

            let query = "after:\(epochSeconds) -label:spam -label:drafts"

            let (recentMessageIds, _) = try await messageFetcher.listMessages(
                query: query,
                maxResults: 50  // Limit to avoid excessive API calls
            )

            guard !recentMessageIds.isEmpty else {
                return []
            }

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
