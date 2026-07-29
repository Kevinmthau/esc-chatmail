import Foundation
import CoreData
import Combine

extension Notification.Name {
    static let syncCompleted = Notification.Name("com.esc.inboxchat.syncCompleted")
    static let pendingActionFailed = Notification.Name("com.esc.inboxchat.pendingActionFailed")
    static let syncMessagesAbandoned = Notification.Name("com.esc.inboxchat.syncMessagesAbandoned")
}

enum ForegroundSyncRequestResult {
    case started
    case alreadyInProgress
    case skippedNoNetwork
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
    private let attachmentDownloader: AttachmentDownloader
    private let networkMonitor: NetworkMonitorService
    private let syncRunCoordinator: SyncRunCoordinator

    private let log = LogCategory.sync.logger

    // MARK: - Initialization

    private convenience init() {
        self.init(
            messageFetcher: MessageFetcher(),
            messagePersister: MessagePersister(),
            historyProcessor: HistoryProcessor(),
            dataCleanupService: DataCleanupService(),
            conversationManager: ConversationManager(),
            coreDataStack: CoreDataStack.shared,
            attachmentDownloader: AttachmentDownloader.shared,
            networkMonitor: NetworkMonitorService(),
            syncRunCoordinator: .shared
        )
    }

    /// Designated initializer with injectable dependencies (production uses the
    /// convenience initializer via `shared`; tests supply their own graph).
    /// Wiring is identical to production: the orchestrators are built from the
    /// injected pieces.
    init(
        messageFetcher: MessageFetcher,
        messagePersister: MessagePersister,
        historyProcessor: HistoryProcessor,
        dataCleanupService: DataCleanupService,
        conversationManager: ConversationManager,
        coreDataStack: CoreDataStack,
        attachmentDownloader: AttachmentDownloader,
        networkMonitor: NetworkMonitorService,
        syncRunCoordinator: SyncRunCoordinator
    ) {
        let reconciliation = SyncReconciliation(
            messageFetcher: messageFetcher
        )

        self.messageFetcher = messageFetcher
        self.messagePersister = messagePersister
        self.historyProcessor = historyProcessor
        self.conversationManager = conversationManager
        self.coreDataStack = coreDataStack
        self.attachmentDownloader = attachmentDownloader
        self.networkMonitor = networkMonitor
        self.syncRunCoordinator = syncRunCoordinator

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
        if await syncRunCoordinator.cancelForegroundRun() {
            uiState.update(isSyncing: false, status: "Sync cancelled")
        }
    }

    /// Performs initial full sync
    func performInitialSync() async throws {
        // Create the foreground task only after acquiring the shared sync-run boundary.
        let syncRunTask = await syncRunCoordinator.beginRunWithTask(kind: .foregroundInitial) {
            Task { [weak self] in
                guard let self else {
                    // This can happen if app is backgrounded/terminated during sync setup
                    Log.warning("SyncEngine deallocated during initial sync setup - sync will not complete", category: .sync)
                    throw CancellationError()
                }
                try await self.performInitialSyncInternal()
            }
        }

        guard let syncRunTask else {
            log.debug("Sync already in progress, skipping initial sync")
            return
        }

        await runSyncTask(syncRunTask, syncType: "Initial")
    }

    /// Performs incremental sync using Gmail history API
    func performIncrementalSync() async throws {
        switch await prepareIncrementalSync() {
        case .started(let syncRunTask):
            await runSyncTask(syncRunTask, syncType: "Incremental")
        case .alreadyInProgress:
            log.debug("Sync already in progress, skipping incremental sync")
        case .skippedNoNetwork:
            return
        }
    }

    func triggerIncrementalSyncIfPossible() async -> ForegroundSyncRequestResult {
        switch await prepareIncrementalSync() {
        case .started(let syncRunTask):
            Task { @MainActor [weak self] in
                guard let self else { return }
                await self.runSyncTask(syncRunTask, syncType: "Incremental")
            }
            return .started
        case .alreadyInProgress:
            log.debug("Sync already in progress, skipping incremental sync")
            return .alreadyInProgress
        case .skippedNoNetwork:
            return .skippedNoNetwork
        }
    }

    func waitForCurrentSyncToComplete() async {
        await syncRunCoordinator.waitUntilIdle()
    }

    /// Executes a sync task with unified error handling
    /// Note: Task is already set atomically by the shared sync-run coordinator.
    private func runSyncTask(_ syncRunTask: SyncRunTask, syncType: String) async {

        do {
            try await syncRunTask.task.value
            await syncRunCoordinator.endRun(syncRunTask.run)
        } catch is CancellationError {
            await syncRunCoordinator.endRun(syncRunTask.run)
            log.info("\(syncType) sync was cancelled")
            uiState.update(isSyncing: false, status: "Sync cancelled")
        } catch {
            await syncRunCoordinator.endRun(syncRunTask.run)
            log.error("\(syncType) sync failed", error: error)
            uiState.update(isSyncing: false, status: "Sync failed: \(formatSyncError(error))")
        }
    }

    // MARK: - Delegated Methods (for BackgroundSyncManager compatibility)

    /// Clears local modifications for synced messages
    func clearLocalModifications(for messageIds: [String]) async {
        await historyProcessor.clearLocalModifications(for: messageIds)
    }

    /// Updates conversation rollups for the explicitly provided modified conversations.
    nonisolated func updateConversationRollups(
        conversationIDs: Set<NSManagedObjectID>,
        in context: NSManagedObjectContext
    ) async {
        guard !conversationIDs.isEmpty else { return }

        await conversationManager.updateRollupsForModifiedConversations(
            conversationIDs: conversationIDs,
            in: context
        )
    }

    /// Updates conversation display names without recomputing rollup fields.
    nonisolated func updateConversationDisplayNames(
        conversationIDs: Set<NSManagedObjectID>,
        in context: NSManagedObjectContext
    ) async {
        guard !conversationIDs.isEmpty else { return }

        await conversationManager.updateConversationDisplayNames(
            conversationIDs: conversationIDs,
            in: context
        )
    }

    /// Prefetches label IDs for background sync
    nonisolated func prefetchLabelIdsForBackground(in context: NSManagedObjectContext) async -> Set<String> {
        return await messagePersister.prefetchLabelIds(in: context)
    }

    /// Saves a message (used by BackgroundSyncManager)
    func saveMessage(
        _ gmailMessage: GmailMessage,
        labelIds: Set<String>? = nil,
        modificationTransaction: ModificationTracker.Transaction,
        in context: NSManagedObjectContext
    ) async {
        // Use centralized AliasManager for alias resolution
        let myAliases = await AliasManager.shared.getAliases(from: context)
        let sendAsAliases = await SendAsAliasManager.shared.getAliases(from: context)

        await messagePersister.saveMessage(
            gmailMessage,
            labelIds: labelIds,
            myAliases: myAliases,
            sendAsAliases: sendAsAliases,
            modificationTransaction: modificationTransaction,
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

        // Incremental sync already posts this; initial sync must too so
        // launch repairs that drained an empty store get re-armed once the
        // first real data lands.
        NotificationCenter.default.post(name: .syncCompleted, object: nil)

        log.info("Initial sync completed: \(result.messagesProcessed) messages, \(result.conversationCount) conversations in \(String(format: "%.1f", result.duration))s")
    }

    private func performIncrementalSyncInternal() async throws {
        uiState.update(isSyncing: true, progress: 0.0, status: "Checking for updates...")

        let result = try await incrementalSyncOrchestrator.performSync(
            progressHandler: { [weak self] progress, status in
                self?.uiState.update(progress: progress, status: status)
            },
            initialSyncFallback: { [weak self] in
                guard let self else {
                    Log.warning("SyncEngine deallocated during initial sync fallback", category: .sync)
                    throw CancellationError()
                }
                try await self.performInitialSyncInternal()
            }
        )

        let finalStatus = result.hadWarnings ? "Sync completed with warnings" : "Sync complete"
        uiState.update(isSyncing: false, progress: 1.0, status: finalStatus)

        log.info("Incremental sync completed: \(result.newMessagesCount) new messages, \(result.labelChangesProcessed) label changes")

        Task {
            await attachmentDownloader.enqueueAllPendingAttachments()
        }
    }

    private enum IncrementalSyncPreparationResult {
        case started(SyncRunTask)
        case alreadyInProgress
        case skippedNoNetwork
    }

    private func prepareIncrementalSync() async -> IncrementalSyncPreparationResult {
        guard await networkMonitor.isNetworkAvailable() else {
            log.info("Network not available, skipping sync")
            uiState.update(isSyncing: false, status: "Network unavailable")
            return .skippedNoNetwork
        }

        let syncRunTask = await syncRunCoordinator.beginRunWithTask(kind: .foregroundIncremental) {
            Task { [weak self] in
                guard let self else {
                    // This can happen if app is backgrounded/terminated during incremental sync setup
                    Log.warning("SyncEngine deallocated during incremental sync setup - sync will not complete", category: .sync)
                    throw CancellationError()
                }
                try await self.performIncrementalSyncInternal()
            }
        }

        guard let syncRunTask else {
            return .alreadyInProgress
        }

        return .started(syncRunTask)
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
            case .quotaExhausted:
                return "Gmail quota reached, will retry later"
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
