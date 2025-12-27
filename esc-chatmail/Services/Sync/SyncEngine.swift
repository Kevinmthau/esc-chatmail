import Foundation
import CoreData
import Combine

extension Notification.Name {
    static let syncCompleted = Notification.Name("com.esc.inboxchat.syncCompleted")
}

// MARK: - Sync Engine

/// Orchestrates email synchronization between Gmail API and local Core Data storage
///
/// This is the main entry point for sync operations. It coordinates between:
/// - InitialSyncOrchestrator: Full sync from Gmail
/// - IncrementalSyncOrchestrator: Delta sync using History API
/// - SyncReconciliation: Catch missed changes
/// - SyncFailureTracker: Handle failures gracefully
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

    private let initialSyncOrchestrator: InitialSyncOrchestrator
    private let incrementalSyncOrchestrator: IncrementalSyncOrchestrator
    private let messageFetcher: MessageFetcher
    private let messagePersister: MessagePersister
    private let historyProcessor: HistoryProcessor
    private let conversationManager: ConversationManager
    private let coreDataStack: CoreDataStack
    private let networkMonitor: NetworkMonitorService
    private let syncStateActor: SyncStateActor

    private let log = LogCategory.sync.logger

    // MARK: - Initialization

    private init() {
        let messageFetcher = MessageFetcher()
        let messagePersister = MessagePersister()
        let historyProcessor = HistoryProcessor()
        let dataCleanupService = DataCleanupService()
        let conversationManager = ConversationManager()
        let coreDataStack = CoreDataStack.shared
        let attachmentDownloader = AttachmentDownloader.shared

        let reconciliation = SyncReconciliation(
            messageFetcher: messageFetcher,
            historyProcessor: historyProcessor
        )

        self.messageFetcher = messageFetcher
        self.messagePersister = messagePersister
        self.historyProcessor = historyProcessor
        self.conversationManager = conversationManager
        self.coreDataStack = coreDataStack
        self.networkMonitor = NetworkMonitorService()
        self.syncStateActor = SyncStateActor()

        self.initialSyncOrchestrator = InitialSyncOrchestrator(
            messageFetcher: messageFetcher,
            messagePersister: messagePersister,
            conversationManager: conversationManager,
            dataCleanupService: dataCleanupService,
            attachmentDownloader: attachmentDownloader,
            coreDataStack: coreDataStack
        )

        self.incrementalSyncOrchestrator = IncrementalSyncOrchestrator(
            messageFetcher: messageFetcher,
            messagePersister: messagePersister,
            historyProcessor: historyProcessor,
            conversationManager: conversationManager,
            dataCleanupService: dataCleanupService,
            reconciliation: reconciliation,
            coreDataStack: coreDataStack
        )
    }

    // MARK: - Public API

    /// Cancels any currently running sync operation
    func cancelSync() async {
        log.info("Cancelling sync")
        await syncStateActor.cancelCurrentSync()
        uiState.update(isSyncing: false, status: "Sync cancelled")
    }

    /// Performs initial full sync
    func performInitialSync() async throws {
        guard await syncStateActor.beginSync() else {
            log.debug("Sync already in progress, skipping initial sync")
            return
        }

        let syncTask = Task {
            try await performInitialSyncInternal()
        }

        await syncStateActor.setSyncTask(syncTask)

        do {
            try await syncTask.value
            await syncStateActor.endSync()
        } catch is CancellationError {
            await syncStateActor.endSync()
            log.info("Initial sync was cancelled")
            uiState.update(isSyncing: false, status: "Sync cancelled")
        } catch {
            await syncStateActor.endSync()
            log.error("Initial sync failed", error: error)
            uiState.update(isSyncing: false, status: "Sync failed: \(error.localizedDescription)")
        }
    }

    /// Performs incremental sync using Gmail history API
    func performIncrementalSync() async throws {
        guard await syncStateActor.beginSync() else {
            log.debug("Sync already in progress, skipping incremental sync")
            return
        }

        guard await networkMonitor.isNetworkAvailable() else {
            await syncStateActor.endSync()
            log.info("Network not available, skipping sync")
            uiState.update(isSyncing: false, status: "Network unavailable")
            return
        }

        let syncTask = Task { [weak self] () -> Void in
            guard let self = self else { return }
            try await self.performIncrementalSyncInternal()
        }

        await syncStateActor.setSyncTask(syncTask)

        do {
            try await syncTask.value
            await syncStateActor.endSync()
        } catch is CancellationError {
            await syncStateActor.endSync()
            log.info("Incremental sync was cancelled")
            uiState.update(isSyncing: false, status: "Sync cancelled")
        } catch {
            await syncStateActor.endSync()
            log.error("Incremental sync failed", error: error)
            uiState.update(isSyncing: false, status: "Sync failed: \(formatSyncError(error))")
        }
    }

    // MARK: - Delegated Methods (for BackgroundSyncManager compatibility)

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
        let myAliases = initialSyncOrchestrator.getMyAliases()
        await messagePersister.saveMessage(
            gmailMessage,
            labelCache: labelCache,
            myAliases: myAliases,
            in: context
        )
    }

    // MARK: - Private Implementation

    private func performInitialSyncInternal() async throws {
        uiState.update(isSyncing: true, progress: 0.0, status: "Starting sync...")

        let result = try await initialSyncOrchestrator.performSync { [weak self] progress, status in
            self?.uiState.update(progress: progress, status: status)
        }

        let finalStatus = result.hadWarnings ? "Sync completed with warnings" : "Sync complete"
        uiState.update(isSyncing: false, progress: 1.0, status: finalStatus)

        log.info("Initial sync completed: \(result.messagesProcessed) messages, \(result.conversationCount) conversations in \(String(format: "%.1f", result.duration))s")
    }

    private func performIncrementalSyncInternal() async throws {
        uiState.update(isSyncing: true, progress: 0.0, status: "Checking for updates...")

        // Share aliases with incremental sync
        incrementalSyncOrchestrator.setMyAliases(initialSyncOrchestrator.getMyAliases())

        let result = try await incrementalSyncOrchestrator.performSync(
            progressHandler: { [weak self] progress, status in
                self?.uiState.update(progress: progress, status: status)
            },
            initialSyncFallback: { [weak self] in
                try await self?.performInitialSyncInternal()
            }
        )

        let finalStatus = result.hadWarnings ? "Sync completed with warnings" : "Sync complete"
        uiState.update(isSyncing: false, progress: 1.0, status: finalStatus)

        log.info("Incremental sync completed: \(result.newMessagesCount) new messages, \(result.labelChangesProcessed) label changes")
    }

    // MARK: - Error Formatting

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
