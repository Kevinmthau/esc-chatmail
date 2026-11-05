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
    /// Refused before fetching anything: the disk is too full, or a recent run hit a full disk
    /// and its backoff has not run out (`SyncStorageBackoff`).
    case skippedInsufficientStorage
}

/// How a run ended, as `SyncEngine.runSyncTask` reports it to the entry point that started it.
private enum SyncRunTaskOutcome: Equatable {
    case succeeded
    case cancelled
    /// Stopped on a full disk (`SyncResourceAbort.isInsufficientStorage`). Kept apart from
    /// `.failed` because it opens the storage backoff rather than an immediate retry.
    case insufficientStorage
    case failed
}

/// Captures the result produced inside the coordinator-owned `Task<Void, Error>`
/// without weakening cancellation registration on that task.
private actor IncrementalSyncResultRecorder {
    private var result: IncrementalSyncResult?

    func record(_ result: IncrementalSyncResult) {
        self.result = result
    }

    func recordedResult() -> IncrementalSyncResult? {
        result
    }
}

// MARK: - Sync Engine

/// Orchestrates email synchronization between Gmail API and local Core Data storage
///
/// This is the main entry point for sync operations. It coordinates between:
/// - InitialSyncOrchestrator: Full sync from Gmail
/// - IncrementalSyncOrchestrator: Delta sync using History API
/// - SyncReconciliation: Catch missed changes
/// - SyncFailureTracker: Handle failures gracefully
///
/// `Sendable` is declared explicitly rather than left implied by `@MainActor`:
/// `BackgroundMailboxSyncExecuting` inherits `Sendable` and is conformed to
/// beside its protocol. A class's `Sendable` conformance must be declared in
/// the class's own source file. Xcode 27's compiler no longer exempts
/// `@MainActor` classes from that rule, and warnings-as-errors turns the
/// violation into a build failure.
@MainActor
final class SyncEngine: ObservableObject, Sendable {
    static let shared = SyncEngine()

    /// Published UI state - use this for UI bindings
    @Published private(set) var uiState = SyncUIState()

    // Convenience accessors for backward compatibility
    var isSyncing: Bool { uiState.isSyncing }
    var syncProgress: Double { uiState.syncProgress }
    var syncStatus: String { uiState.syncStatus }

    /// True while sync is held back because the disk is full: set when a run is refused or
    /// stops on a full disk, cleared by the next run that finishes.
    @Published private(set) var isBlockedByInsufficientStorage = false

    static let insufficientStorageStatus = "Not enough storage to sync new mail"

    /// Admission and backoff for a full disk. Main-actor state, read before every run starts.
    private var storageBackoff = SyncStorageBackoff()

    // MARK: - Dependencies

    private let initialSyncOrchestrator: InitialSyncOrchestrator
    private let incrementalSyncOrchestrator: IncrementalSyncOrchestrator
    private let messageFetcher: MessageFetcher
    private let coreDataStack: CoreDataStack
    private let attachmentDownloader: AttachmentDownloader
    private let networkMonitor: NetworkMonitorService
    private let syncRunCoordinator: SyncRunCoordinator
    private let clock: any SyncClock
    private let availableStorageBytes: @Sendable () -> Int64?

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
        syncRunCoordinator: SyncRunCoordinator,
        clock: any SyncClock = SystemSyncClock(),
        availableStorageBytes: @escaping @Sendable () -> Int64? = { StoreVolumeFreeSpace.availableBytes() }
    ) {
        let reconciliation = SyncReconciliation(
            messageFetcher: messageFetcher
        )

        self.messageFetcher = messageFetcher
        self.coreDataStack = coreDataStack
        self.attachmentDownloader = attachmentDownloader
        self.networkMonitor = networkMonitor
        self.syncRunCoordinator = syncRunCoordinator
        self.clock = clock
        self.availableStorageBytes = availableStorageBytes

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
            coreDataStack: coreDataStack,
            authenticatedAccountEmail: {
                AuthSession.shared.currentOrPersistedUserEmail()
            }
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
        guard admitsRunForStorage() else { return }
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

    func triggerIncrementalSyncIfPossible(
        completion: @escaping @MainActor @Sendable (Bool) -> Void
    ) async -> ForegroundSyncRequestResult {
        let resultRecorder = IncrementalSyncResultRecorder()
        switch await prepareIncrementalSync(resultRecorder: resultRecorder) {
        case .started(let syncRunTask):
            Task { @MainActor [weak self] in
                guard let self else { return }
                let outcome = await self.runSyncTask(
                    syncRunTask,
                    syncType: "Incremental"
                )
                guard outcome == .succeeded,
                      let result = await resultRecorder.recordedResult() else {
                    return
                }
                completion(result.needsFollowUp)
            }
            return .started
        case .alreadyInProgress:
            log.debug("Sync already in progress, skipping incremental sync")
            return .alreadyInProgress
        case .skippedNoNetwork:
            return .skippedNoNetwork
        case .skippedInsufficientStorage:
            return .skippedInsufficientStorage
        }
    }

    /// Runs the same model-v3 incremental executor for a system background
    /// launch, but keeps ownership of the concrete run task so cancelling the
    /// awaiting `BGTask` wrapper cannot leave mailbox work running past expiry.
    func performIncrementalSyncForBackground(
        budget: BackgroundMailboxSyncBudget
    ) async -> BackgroundMailboxSyncExecutionResult {
        let resultRecorder = IncrementalSyncResultRecorder()
        switch await prepareIncrementalSync(
            resultRecorder: resultRecorder,
            historyPageLimit: budget.historyPageLimit,
            historyPageSize: budget.historyPageSize,
            allowsExpensiveRecovery: budget.allowsExpensiveRecovery
        ) {
        case .started(let syncRunTask):
            let outcome = await withTaskCancellationHandler {
                await runSyncTask(syncRunTask, syncType: "Background incremental")
            } onCancel: {
                syncRunTask.task.cancel()
            }
            if outcome == .insufficientStorage {
                return .deferredForInsufficientStorage
            }
            guard outcome == .succeeded,
                  let result = await resultRecorder.recordedResult() else {
                return .failed
            }
            return result.needsFollowUp ? .needsFollowUp : .completed
        case .alreadyInProgress:
            let activeKind = await syncRunCoordinator.activeRunKind()
            log.debug("Background mailbox sync blocked by \(activeKind?.rawValue ?? "account transition")")
            return .blocked(by: activeKind)
        case .skippedNoNetwork:
            return .failed
        case .skippedInsufficientStorage:
            return .deferredForInsufficientStorage
        }
    }

    func waitForCurrentSyncToComplete() async {
        await syncRunCoordinator.waitUntilIdle()
    }

    /// Executes a sync task with unified error handling
    /// Note: Task is already set atomically by the shared sync-run coordinator.
    @discardableResult
    private func runSyncTask(_ syncRunTask: SyncRunTask, syncType: String) async -> SyncRunTaskOutcome {

        do {
            try await syncRunTask.task.value
            await syncRunCoordinator.endRun(syncRunTask.run)
            storageBackoff.recordSuccessfulRun()
            setBlockedByInsufficientStorage(false)
            return .succeeded
        } catch is CancellationError {
            await syncRunCoordinator.endRun(syncRunTask.run)
            log.info("\(syncType) sync was cancelled")
            uiState.update(isSyncing: false, status: "Sync cancelled")
            return .cancelled
        } catch let error where SyncResourceAbort.isInsufficientStorage(error) {
            await syncRunCoordinator.endRun(syncRunTask.run)
            // The run rolled back and recorded no per-message failure, so the ledger and the
            // escape-hatch counter are untouched. Only the backoff moves.
            storageBackoff.recordInsufficientStorage(now: clock.now(), availableBytes: availableStorageBytes())
            setBlockedByInsufficientStorage(true)
            log.error("\(syncType) sync stopped: not enough storage", error: error)
            uiState.update(isSyncing: false, status: Self.insufficientStorageStatus)
            return .insufficientStorage
        } catch {
            await syncRunCoordinator.endRun(syncRunTask.run)
            log.error("\(syncType) sync failed", error: error)
            uiState.update(isSyncing: false, status: "Sync failed: \(formatSyncError(error))")
            return .failed
        }
    }

    /// Publishes only a change: `@Published` notifies on every assignment, and the conversation
    /// list observes this engine, so clearing it after every successful run would re-render the
    /// list once a minute for nothing.
    private func setBlockedByInsufficientStorage(_ isBlocked: Bool) {
        guard isBlockedByInsufficientStorage != isBlocked else { return }
        isBlockedByInsufficientStorage = isBlocked
    }

    /// Refuses a run the disk cannot hold, before it fetches anything (`SyncStorageBackoff`).
    private func admitsRunForStorage() -> Bool {
        guard storageBackoff.admitsRun(now: clock.now(), availableBytes: availableStorageBytes()) else {
            log.info("Not enough storage to sync; skipping run")
            setBlockedByInsufficientStorage(true)
            uiState.update(isSyncing: false, status: Self.insufficientStorageStatus)
            return false
        }
        return true
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

    private func performIncrementalSyncInternal(
        historyPageLimit: Int? = nil,
        historyPageSize: Int? = nil,
        allowsExpensiveRecovery: Bool = true
    ) async throws -> IncrementalSyncResult {
        uiState.update(isSyncing: true, progress: 0.0, status: "Checking for updates...")

        let result = try await incrementalSyncOrchestrator.performSync(
            historyPageLimit: historyPageLimit,
            historyPageSize: historyPageSize,
            allowsExpensiveRecovery: allowsExpensiveRecovery,
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

        attachmentDownloader.schedulePendingAttachmentDownloads()
        return result
    }

    private enum IncrementalSyncPreparationResult {
        case started(SyncRunTask)
        case alreadyInProgress
        case skippedNoNetwork
        case skippedInsufficientStorage
    }

    private func prepareIncrementalSync(
        resultRecorder: IncrementalSyncResultRecorder? = nil,
        historyPageLimit: Int? = nil,
        historyPageSize: Int? = nil,
        allowsExpensiveRecovery: Bool = true
    ) async -> IncrementalSyncPreparationResult {
        // Ahead of the network check: when both refuse, the full disk is what the user can fix.
        guard admitsRunForStorage() else {
            return .skippedInsufficientStorage
        }
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
                let result = try await self.performIncrementalSyncInternal(
                    historyPageLimit: historyPageLimit,
                    historyPageSize: historyPageSize,
                    allowsExpensiveRecovery: allowsExpensiveRecovery
                )
                if let resultRecorder {
                    await resultRecorder.record(result)
                }
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
