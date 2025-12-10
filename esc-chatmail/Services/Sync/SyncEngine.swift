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

            // Build query for messages after installation
            let installationTimestamp = KeychainService.shared.getOrCreateInstallationTimestamp()
            let epochSeconds = Int(installationTimestamp.timeIntervalSince1970)
            let gmailQuery = "after:\(epochSeconds) -label:spam -label:drafts"

            print("Syncing messages after installation: \(installationTimestamp)")

            // Stream process messages in batches
            var pageToken: String? = nil
            var totalProcessed = 0

            uiState.update(progress: 0.3, status: "Fetching messages...")

            repeat {
                try Task.checkCancellation()

                let (messageIds, nextPageToken) = try await messageFetcher.listMessages(
                    query: gmailQuery,
                    pageToken: pageToken
                )

                // Process this page in batches
                // Note: labelCache contains NSManagedObjects which aren't Sendable, but we ensure
                // all Core Data operations happen on the same background context
                nonisolated(unsafe) let unsafeLabelCache = labelCache

                for batch in messageIds.chunked(into: SyncConfig.messageBatchSize) {
                    try Task.checkCancellation()

                    _ = await messageFetcher.fetchBatch(batch) { [weak self] message in
                        guard let self = self else { return }
                        await self.messagePersister.saveMessage(
                            message,
                            labelCache: unsafeLabelCache,
                            myAliases: self.myAliases,
                            in: context
                        )
                    }

                    totalProcessed += batch.count

                    await MainActor.run {
                        self.uiState.update(
                            progress: min(0.9, 0.3 + (Double(totalProcessed) / 10000.0) * 0.6),
                            status: "Processing messages... \(totalProcessed)"
                        )
                    }
                }

                pageToken = nextPageToken
            } while pageToken != nil

            uiState.update(progress: 0.9, status: "Processed \(totalProcessed) messages")

            // Update conversation rollups
            let rollupStartTime = CFAbsoluteTimeGetCurrent()
            await conversationManager.updateAllConversationRollups(in: context)
            let rollupDuration = CFAbsoluteTimeGetCurrent() - rollupStartTime

            let conversationCount = await countConversations(in: context)

            // Save changes (use async to avoid blocking main thread)
            let saveStartTime = CFAbsoluteTimeGetCurrent()
            do {
                try await coreDataStack.saveAsync(context: context)
                let saveDuration = CFAbsoluteTimeGetCurrent() - saveStartTime
                performanceLogger.logSave(insertions: totalProcessed, updates: 0, deletions: 0, duration: saveDuration)
            } catch {
                print("Failed to save sync data: \(error)")
                throw error
            }

            // Update history ID
            await messagePersister.updateAccountHistoryId(profile.historyId)

            // Start downloading attachments
            Task {
                await attachmentDownloader.enqueueAllPendingAttachments()
            }

            // Log summary
            let totalDuration = CFAbsoluteTimeGetCurrent() - syncStartTime
            performanceLogger.endOperation("InitialSync", signpostID: signpostID)
            performanceLogger.logSyncSummary(
                messagesProcessed: totalProcessed,
                conversationsUpdated: conversationCount,
                totalDuration: totalDuration
            )

            #if DEBUG
            print("📊 Conversation rollup took \(String(format: "%.2f", rollupDuration))s")
            #endif

            uiState.update(isSyncing: false, progress: 1.0, status: "Sync complete")

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

                if let history = history {
                    print("Received \(history.count) history records")

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
                }

                if let newHistoryId = newHistoryId {
                    latestHistoryId = newHistoryId
                }

                pageToken = nextPageToken
            } while pageToken != nil

            try Task.checkCancellation()

            // Fetch new messages
            if !allNewMessageIds.isEmpty {
                uiState.update(progress: 0.3, status: "Fetching \(allNewMessageIds.count) new messages...")

                // Note: labelCache contains NSManagedObjects which aren't Sendable, but we ensure
                // all Core Data operations happen on the same background context
                nonisolated(unsafe) let unsafeLabelCache = labelCache

                var processedCount = 0

                for batch in allNewMessageIds.chunked(into: SyncConfig.messageBatchSize) {
                    try Task.checkCancellation()

                    _ = await messageFetcher.fetchBatch(batch) { [weak self] message in
                        guard let self = self else { return }
                        await self.messagePersister.saveMessage(
                            message,
                            labelCache: unsafeLabelCache,
                            myAliases: self.myAliases,
                            in: context
                        )
                    }

                    processedCount += batch.count
                    let progress = 0.3 + (Double(processedCount) / Double(allNewMessageIds.count)) * 0.5

                    await MainActor.run {
                        self.uiState.update(
                            progress: progress,
                            status: "Processing messages... \(processedCount)/\(allNewMessageIds.count)"
                        )
                    }
                }
            }

            uiState.update(progress: 0.85, status: "Updating conversations...")

            try Task.checkCancellation()

            // Cleanup and rollups
            await conversationManager.updateAllConversationRollups(in: context)
            await dataCleanupService.runIncrementalCleanup(in: context)

            uiState.update(progress: 0.95, status: "Saving changes...")

            await messagePersister.updateAccountHistoryId(latestHistoryId)

            do {
                try await coreDataStack.saveAsync(context: context)
            } catch {
                print("Failed to save incremental sync: \(error)")
                throw error
            }

            coreDataStack.viewContext.refreshAllObjects()
            uiState.update(isSyncing: false, progress: 1.0, status: "Sync complete")

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

                if !(error is URLError) && !(error is APIError) {
                    throw error
                }
            }
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
