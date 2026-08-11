import Foundation
import BackgroundTasks
import CoreData
import os

enum BackgroundSyncRetryAction: Equatable {
    case none
    case failureBackoff
    case catchUp
}

struct BackgroundSyncCompletionDisposition: Equatable {
    let historyIdToStore: String?
    let continuationState: BackgroundSyncContinuationState?
    let retryAction: BackgroundSyncRetryAction
    let shouldResetRetryState: Bool
}

enum BackgroundMailboxSyncExecutionResult: Equatable, Sendable {
    case completed
    case needsFollowUp
    case blocked(by: SyncRunKind?)
    case failed
}

/// The model-v3 mailbox sync entry point used by `BGTask` launches. The
/// production implementation owns and cancels the exact incremental run it
/// starts, while tests can exercise the background hand-off without creating
/// `BGTask` instances (which Apple does not expose public initializers for).
@MainActor
protocol BackgroundMailboxSyncExecuting: AnyObject, Sendable {
    func performIncrementalSyncForBackground() async -> BackgroundMailboxSyncExecutionResult
}

extension SyncEngine: BackgroundMailboxSyncExecuting {}

/// Main orchestrator for background sync operations
final class BackgroundSyncManager {
    static let shared = BackgroundSyncManager()

    static let catchUpRetryDelay: TimeInterval = 5 * 60

    // MARK: - Components

    private let taskScheduler: any BackgroundTaskScheduling
    private let stateManager: BackgroundSyncStateManager
    private let errorHandler = BackgroundSyncErrorHandler()
    private let messageProcessor: BackgroundMessageProcessor
    private let authSessionProvider: @MainActor @Sendable () -> AuthSession
    private let apiClientProvider: @MainActor @Sendable () -> GmailAPIClientProtocol
    private let syncRunCoordinator: SyncRunCoordinator
    private let defaults: UserDefaults
    private let authoritativeSyncExecutorProvider: @MainActor @Sendable () -> any BackgroundMailboxSyncExecuting
    private let authoritativeSyncReadiness: @Sendable () async -> Bool
    private let authoritativeSyncIsAuthenticated: @MainActor @Sendable () -> Bool
    /// Characterization tests can still exercise the retired delta writer, but
    /// production routes every new and already-submitted request through the
    /// same model-v3 executor used for foreground sync.
    private let legacyDeltaSyncEnabled: Bool

    init(
        taskScheduler: any BackgroundTaskScheduling = BackgroundTaskScheduler.shared,
        coreDataStack: CoreDataStack = .shared,
        defaults: UserDefaults = .standard,
        syncRunCoordinator: SyncRunCoordinator = .shared,
        legacyDeltaSyncEnabled: Bool = false,
        authSessionProvider: @escaping @MainActor @Sendable () -> AuthSession = { AuthSession.shared },
        apiClientProvider: @escaping @MainActor @Sendable () -> GmailAPIClientProtocol = { GmailAPIClient.shared },
        authoritativeSyncExecutorProvider: @escaping @MainActor @Sendable () -> any BackgroundMailboxSyncExecuting = {
            SyncEngine.shared
        },
        authoritativeSyncReadiness: @escaping @Sendable () async -> Bool = {
            await AppStartupBootstrap.shared.prepareForBackgroundSync()
        },
        authoritativeSyncIsAuthenticated: @escaping @MainActor @Sendable () -> Bool = {
            AuthSession.shared.isAuthenticated
        },
        syncCoordinatorProvider: @escaping @MainActor @Sendable () -> BackgroundSyncMessageCoordinating = {
            SyncEngine.shared
        }
    ) {
        self.taskScheduler = taskScheduler
        self.stateManager = BackgroundSyncStateManager(
            coreDataStack: coreDataStack,
            defaults: defaults
        )
        self.messageProcessor = BackgroundMessageProcessor(
            coreDataStack: coreDataStack,
            apiClientProvider: apiClientProvider,
            syncCoordinatorProvider: syncCoordinatorProvider
        )
        self.authSessionProvider = authSessionProvider
        self.apiClientProvider = apiClientProvider
        self.syncRunCoordinator = syncRunCoordinator
        self.defaults = defaults
        self.authoritativeSyncExecutorProvider = authoritativeSyncExecutorProvider
        self.authoritativeSyncReadiness = authoritativeSyncReadiness
        self.authoritativeSyncIsAuthenticated = authoritativeSyncIsAuthenticated
        self.legacyDeltaSyncEnabled = legacyDeltaSyncEnabled

        setupTaskHandlers()
    }

    private func setupTaskHandlers() {
        taskScheduler.onAppRefresh = { [weak self] task in
            self?.handleAppRefresh(task: task)
        }
        taskScheduler.onProcessing = { [weak self] task in
            self?.handleProcessing(task: task)
        }
    }

    // MARK: - Public API

    func registerBackgroundTasks() {
        taskScheduler.registerBackgroundTasks()
    }

    func scheduleAppRefresh() {
        taskScheduler.scheduleAppRefresh()
    }

    func scheduleProcessingTask() {
        taskScheduler.scheduleProcessingTask()
    }

    // MARK: - Task Handlers

    private func handleAppRefresh(task: BGAppRefreshTask) {
        taskScheduler.scheduleAppRefresh()
        runBackgroundTask(task, isProcessingTask: false)
    }

    private func handleProcessing(task: BGProcessingTask) {
        taskScheduler.scheduleProcessingTask()
        runBackgroundTask(task, isProcessingTask: true)
    }

    /// Shared implementation for both app-refresh and processing background tasks.
    /// Uses an atomic flag to ensure `setTaskCompleted` is called exactly once,
    /// preventing a race between normal completion and the expiration handler.
    private func runBackgroundTask(_ task: BGTask, isProcessingTask: Bool) {
        let latch = BackgroundTaskCompletionLatch { success in
            task.setTaskCompleted(success: success)
        }

        let backgroundTask = Task { [weak self] in
            guard let self = self else {
                latch.complete(success: false)
                return
            }
            let success: Bool
            if self.legacyDeltaSyncEnabled {
                success = await self.performDeltaSync(isProcessingTask: isProcessingTask)
            } else {
                success = await self.performAuthoritativeSync()
            }
            latch.complete(success: success)
        }

        task.expirationHandler = {
            backgroundTask.cancel()
            latch.complete(success: false)
        }
    }

    /// Executes the authoritative model-v3 sync and preserves structured task
    /// cancellation so a `BGTask` expiration reaches the exact underlying run.
    func performAuthoritativeSync() async -> Bool {
        guard !Task.isCancelled else { return false }
        guard await authoritativeSyncReadiness() else {
            // Bootstrap failure is a real failure, not a verdict on the mailbox,
            // so it takes the same bounded backoff as any other failed run. An
            // expired task is different: it must not queue more work.
            if !Task.isCancelled {
                scheduleFailureBackoffRetry()
            }
            return false
        }
        guard !Task.isCancelled else { return false }
        guard await MainActor.run(body: authoritativeSyncIsAuthenticated) else {
            // A stale request delivered after logout is a successful no-op. The
            // bootstrap has already completed any interrupted account cleanup.
            return true
        }

        BackgroundSyncStateManager.clearContinuationState(in: defaults)
        let executor = await MainActor.run { authoritativeSyncExecutorProvider() }
        let result = await executor.performIncrementalSyncForBackground()
        // The system asked an expired task to stop: the handlers already queued
        // the next ordinary cycle before this run started, so schedule nothing.
        guard !Task.isCancelled else { return false }

        switch result {
        case .completed:
            // Mirrors the legacy path's `shouldResetRetryState`: a clean run
            // returns the shared backoff to its initial delay so the next
            // failure does not inherit a spent retry budget.
            stateManager.resetRetryCount()
            return true
        case .needsFollowUp:
            scheduleCatchUpRetry()
            return false
        case .blocked(let activeKind):
            guard Self.shouldScheduleRetryWhenBlocked(by: activeKind) else {
                return true
            }
            scheduleCatchUpRetry()
            return false
        case .failed:
            // Without this the run reported failure and scheduled nothing, so a
            // transient failure waited out the ordinary 15-minute refresh cadence
            // instead of the bounded exponential backoff every other failure
            // path uses.
            scheduleFailureBackoffRetry()
            return false
        }
    }

    // MARK: - Sync Orchestration

    private func performDeltaSync(isProcessingTask: Bool) async -> Bool {
        guard let syncRun = await syncRunCoordinator.beginRun(kind: .background) else {
            let activeKind = await syncRunCoordinator.activeRunKind()
            Log.info("Skipping background sync because \(activeKind?.rawValue ?? "another run") is active", category: .background)

            guard Self.shouldScheduleRetryWhenBlocked(by: activeKind) else {
                return true
            }

            scheduleCatchUpRetry()
            return false
        }

        let success = await performDeltaSyncWithinRun(isProcessingTask: isProcessingTask)
        await syncRunCoordinator.endRun(syncRun)
        return success
    }

    private func performDeltaSyncWithinRun(isProcessingTask: Bool) async -> Bool {
        do {
            let authSession = await MainActor.run { authSessionProvider() }
            _ = try await authSession.withFreshToken()
            let currentAccountEmail = await MainActor.run { authSession.currentOrPersistedUserEmail() }
            let historyId = await stateManager.getStoredHistoryId()

            if let continuationState = stateManager.getContinuationState() {
                if !continuationState.isCompatible(
                    storedHistoryId: historyId,
                    currentAccountEmail: currentAccountEmail
                ) {
                    stateManager.clearContinuationState()
                    Log.warning(
                        "Cleared stale background sync continuation state because the stored account or history cursor changed",
                        category: .background
                    )
                } else {
                    switch continuationState.mode {
                    case .history:
                        guard let startHistoryId = continuationState.startHistoryId,
                              let pageToken = continuationState.pageToken else {
                            stateManager.clearContinuationState()
                            Log.warning("Cleared invalid background history continuation state", category: .background)
                            break
                        }

                        return await performHistorySync(
                            startHistoryId: startHistoryId,
                            initialPageToken: pageToken,
                            isProcessingTask: isProcessingTask,
                            accountEmail: currentAccountEmail
                        )

                    case .partial:
                        guard let query = continuationState.query,
                              let maxResults = continuationState.maxResults,
                              let watermarkHistoryId = continuationState.watermarkHistoryId else {
                            stateManager.clearContinuationState()
                            Log.warning("Cleared invalid background partial continuation state", category: .background)
                            break
                        }

                        return await performPartialSync(
                            query: query,
                            initialPageToken: continuationState.pageToken,
                            maxResults: maxResults,
                            startHistoryId: continuationState.startHistoryId,
                            watermarkHistoryId: watermarkHistoryId,
                            isProcessingTask: isProcessingTask,
                            accountEmail: continuationState.accountEmail
                        )
                    }
                }
            }

            if let historyId = historyId {
                return await performHistorySync(
                    startHistoryId: historyId,
                    isProcessingTask: isProcessingTask,
                    accountEmail: currentAccountEmail
                )
            } else {
                return await performPartialSync(
                    startHistoryId: nil,
                    isProcessingTask: isProcessingTask,
                    accountEmail: currentAccountEmail
                )
            }
        } catch {
            Log.error("Background sync error", category: .background, error: error)
            handleSyncError()
            return false
        }
    }

    /// Performs the retired delta writer's history walk. Internal so its
    /// persisted-continuation recovery can be pinned without constructing a
    /// private `BGTask` subclass in tests.
    func performHistorySync(
        startHistoryId: String,
        initialPageToken: String? = nil,
        isProcessingTask: Bool,
        accountEmail: String?
    ) async -> Bool {
        do {
            let apiClient = await MainActor.run { apiClientProvider() }
            var allHistories: [HistoryRecord] = []
            var pageToken: String? = initialPageToken
            let maxPages = isProcessingTask ? 10 : 3
            var pageCount = 0
            var latestHistoryId: String? = nil

            repeat {
                let historyResponse = try await apiClient.listHistory(startHistoryId: startHistoryId, pageToken: pageToken)

                if let histories = historyResponse.history {
                    allHistories.append(contentsOf: histories)
                } else if historyResponse.history == nil && pageCount == 0 {
                    Log.debug("No history changes since last sync", category: .background)
                }

                pageToken = historyResponse.nextPageToken
                pageCount += 1

                if let newHistoryId = historyResponse.historyId {
                    latestHistoryId = newHistoryId
                }
            } while pageToken != nil && pageCount < maxPages

            let didTruncateHistoryPagination = pageToken != nil

            let processingResult: BackgroundMessageProcessingResult
            if !allHistories.isEmpty {
                processingResult = await messageProcessor.processHistoryChanges(histories: allHistories)
            } else {
                processingResult = .empty
            }

            let continuationState: BackgroundSyncContinuationState? = {
                guard didTruncateHistoryPagination,
                      !processingResult.hadFetchFailures,
                      let pageToken else { return nil }
                return .history(
                    startHistoryId: startHistoryId,
                    pageToken: pageToken,
                    accountEmail: accountEmail
                )
            }()
            let disposition = Self.completionDisposition(
                catchUpState: continuationState,
                hadFetchFailures: processingResult.hadFetchFailures,
                latestHistoryId: latestHistoryId
            )

            if continuationState != nil, didTruncateHistoryPagination {
                Log.warning(
                    "Background history sync reached page limit (\(maxPages)); stored continuation page token for catch-up retry",
                    category: .background
                )
            } else if didTruncateHistoryPagination {
                Log.warning(
                    "Background history sync reached page limit (\(maxPages)) but had fetch failures; retrying before advancing continuation",
                    category: .background
                )
            }

            if processingResult.hadFetchFailures {
                Log.warning(
                    "Background history sync had \(processingResult.failedFetchCount) message fetch failures; keeping stored historyId and scheduling retry",
                    category: .background
                )
            }

            return await finalizeBackgroundSync(disposition)

        } catch {
            return await handleHistorySyncError(
                error,
                startHistoryId: startHistoryId,
                initialPageToken: initialPageToken,
                isProcessingTask: isProcessingTask,
                accountEmail: accountEmail
            )
        }
    }

    private func handleHistorySyncError(
        _ error: Error,
        startHistoryId: String,
        initialPageToken: String?,
        isProcessingTask: Bool,
        accountEmail: String?
    ) async -> Bool {
        // A rejected persisted page token does not invalidate the frozen
        // history cursor. Drop only that token and replay from the cursor once;
        // the recursive call has no initial token, which bounds recovery if
        // Gmail rejects the replay too.
        if initialPageToken != nil,
           let apiError = error as? APIError,
           case .invalidHistoryPageToken = apiError {
            stateManager.clearContinuationState()
            Log.warning(
                "Cleared rejected background history continuation and replaying from its saved cursor",
                category: .background
            )
            return await performHistorySync(
                startHistoryId: startHistoryId,
                initialPageToken: nil,
                isProcessingTask: isProcessingTask,
                accountEmail: accountEmail
            )
        }

        let action = errorHandler.handleError(error)

        switch action {
        case .retry:
            handleSyncError()
            return false

        case .partialSync:
            stateManager.clearContinuationState()
            return await performPartialSync(
                startHistoryId: startHistoryId,
                isProcessingTask: isProcessingTask,
                accountEmail: accountEmail
            )

        case .tokenRefreshAndRetry:
            do {
                let authSession = await MainActor.run { authSessionProvider() }
                _ = try await authSession.withFreshToken()
                return await performHistorySync(
                    startHistoryId: startHistoryId,
                    initialPageToken: initialPageToken,
                    isProcessingTask: isProcessingTask,
                    accountEmail: accountEmail
                )
            } catch {
                Log.error("Token refresh failed", category: .background, error: error)
                handleSyncError()
                return false
            }

        case .abort:
            handleSyncError()
            return false

        case .abortNoRetry:
            return false
        }
    }

    /// Performs a bounded partial mailbox scan. Internal so orchestration tests
    /// can pin the pre-scan watermark and continuation contracts end to end.
    func performPartialSync(
        query: String? = nil,
        initialPageToken: String? = nil,
        maxResults: Int? = nil,
        startHistoryId: String? = nil,
        watermarkHistoryId: String? = nil,
        isProcessingTask: Bool,
        accountEmail: String?
    ) async -> Bool {
        do {
            let apiClient = await MainActor.run { apiClientProvider() }
            let maxResults = maxResults ?? (isProcessingTask ? 100 : 50)
            let maxPages = isProcessingTask ? 10 : 3

            let query = query ?? buildPartialSyncQuery()

            // Capture the replacement cursor before the first mailbox page.
            // Changes after this point are therefore newer than the cursor and
            // remain visible to the next history sync even if pagination does
            // not include them. A resumed scan reuses the original watermark;
            // taking a new one would recreate the post-scan gap across tasks.
            let syncWatermark: (historyId: String, accountEmail: String)
            if let watermarkHistoryId {
                guard let accountEmail else {
                    Log.error("Partial sync continuation is missing its account scope", category: .background)
                    stateManager.clearContinuationState()
                    handleSyncError()
                    return false
                }
                syncWatermark = (watermarkHistoryId, accountEmail)
            } else {
                let profile = try await apiClient.getProfile()
                if let accountEmail,
                   accountEmail.caseInsensitiveCompare(profile.emailAddress) != .orderedSame {
                    Log.error(
                        "Aborting background partial sync because the authenticated profile does not match the current account",
                        category: .background
                    )
                    handleSyncError()
                    return false
                }
                syncWatermark = (profile.historyId, profile.emailAddress)
            }

            // Save the chunk's starting position before any enumeration or
            // message persistence. If the task fails or expires after saving
            // only part of the chunk, the next attempt reuses this watermark
            // and safely replays the same pages instead of opening a gap.
            let inProgressCheckpoint = BackgroundSyncContinuationState.partial(
                query: query,
                pageToken: initialPageToken,
                maxResults: maxResults,
                startHistoryId: startHistoryId,
                watermarkHistoryId: syncWatermark.historyId,
                accountEmail: syncWatermark.accountEmail
            )
            try stateManager.storeContinuationState(inProgressCheckpoint)
            try Task.checkCancellation()

            var allMessageIds: Set<String> = []
            var pageToken: String? = initialPageToken
            var pageCount = 0

            repeat {
                try Task.checkCancellation()
                let response = try await apiClient.listMessages(
                    pageToken: pageToken,
                    maxResults: maxResults,
                    query: query
                )
                if let messages = response.messages {
                    allMessageIds.formUnion(messages.map { $0.id })
                }
                pageToken = response.nextPageToken
                pageCount += 1
            } while pageToken != nil && pageCount < maxPages

            let processingResult: BackgroundMessageProcessingResult
            if !allMessageIds.isEmpty {
                processingResult = await messageProcessor.fetchAndStoreMessages(messageIds: Array(allMessageIds))
            } else {
                processingResult = .empty
            }

            let didTruncateMessagePagination = pageToken != nil
            let continuationState: BackgroundSyncContinuationState? = {
                guard didTruncateMessagePagination,
                      !processingResult.hadFetchFailures,
                      let pageToken else { return nil }
                return .partial(
                    query: query,
                    pageToken: pageToken,
                    maxResults: maxResults,
                    startHistoryId: startHistoryId,
                    watermarkHistoryId: syncWatermark.historyId,
                    accountEmail: syncWatermark.accountEmail
                )
            }()
            let disposition = Self.completionDisposition(
                catchUpState: continuationState,
                hadFetchFailures: processingResult.hadFetchFailures,
                latestHistoryId: syncWatermark.historyId
            )

            if continuationState != nil, didTruncateMessagePagination {
                Log.warning(
                    "Background partial sync reached page limit (\(maxPages)); stored continuation page token for catch-up retry",
                    category: .background
                )
            } else if didTruncateMessagePagination {
                Log.warning(
                    "Background partial sync reached page limit (\(maxPages)) but had fetch failures; retrying before advancing continuation",
                    category: .background
                )
            }

            if processingResult.hadFetchFailures {
                Log.warning(
                    "Background partial sync had \(processingResult.failedFetchCount) message fetch failures; keeping stored historyId and scheduling retry",
                    category: .background
                )
            }

            // An expired BGTask must not commit a terminal cursor or advance
            // its checkpoint after the system has requested cancellation.
            try Task.checkCancellation()

            return await finalizeBackgroundSync(
                disposition,
                accountEmail: syncWatermark.accountEmail
            )
        } catch is CancellationError {
            Log.info("Partial sync cancelled; keeping its in-progress checkpoint", category: .background)
            return false
        } catch {
            Log.error("Partial sync error", category: .background, error: error)
            handleSyncError()
            return false
        }
    }

    private func buildPartialSyncQuery() -> String {
        let installTimestamp = defaults.double(forKey: "installTimestamp")

        if installTimestamp > 0 {
            let cutoffTimestamp = Int(installTimestamp) - 300 // 5 min buffer
            return "after:\(cutoffTimestamp) -label:spam -label:drafts -label:trash"
        }

        let oneDayAgo = Int(Date().timeIntervalSince1970) - (24 * 60 * 60)
        return "after:\(oneDayAgo) -label:spam -label:drafts -label:trash"
    }

    // MARK: - Error Handling

    private func handleSyncError() {
        guard legacyDeltaSyncEnabled else { return }
        scheduleFailureBackoffRetry()
    }

    /// Exponential backoff shared by every genuinely failed run.
    ///
    /// `incrementRetryAndGetBackoff()` is a rolling three-failure window, not a
    /// terminal budget: it returns 60s, then 120s, then nil while resetting the
    /// counter and backoff to their initial values. So a permanently-failing
    /// account settles into a 60s / 120s / skip cycle rather than escalating
    /// without bound or giving up. The skipped third retry is deliberate — the
    /// app-refresh and processing handlers already queued the next ordinary
    /// cycle before this run began, so that slot is covered by normal cadence.
    private func scheduleFailureBackoffRetry() {
        if let backoff = stateManager.incrementRetryAndGetBackoff() {
            taskScheduler.scheduleRetryAfterBackoff(backoff)
        }
    }

    private func scheduleCatchUpRetry() {
        // Catch-up is progress, not failure, so bypass the exponential-backoff
        // retry counter and reschedule on a short fixed delay instead.
        taskScheduler.scheduleRetryAfterBackoff(Self.catchUpRetryDelay)
    }

    private func finalizeBackgroundSync(
        _ disposition: BackgroundSyncCompletionDisposition,
        accountEmail: String? = nil
    ) async -> Bool {
        switch disposition.retryAction {
        case .none:
            do {
                if let historyId = disposition.historyIdToStore {
                    try await stateManager.storeHistoryId(historyId, accountEmail: accountEmail)
                }
                stateManager.clearContinuationState()
            } catch {
                Log.error("Failed to store background sync state", category: .background, error: error)
                handleSyncError()
                return false
            }

            if disposition.shouldResetRetryState {
                stateManager.resetRetryCount()
            }
            return true

        case .failureBackoff:
            handleSyncError()
            return false

        case .catchUp:
            do {
                guard let continuationState = disposition.continuationState else {
                    Log.warning("Background catch-up retry requested without continuation state", category: .background)
                    handleSyncError()
                    return false
                }

                try stateManager.storeContinuationState(continuationState)
            } catch {
                Log.error("Failed to store background sync continuation state", category: .background, error: error)
                handleSyncError()
                return false
            }

            scheduleCatchUpRetry()
            return false
        }
    }

    static func completionDisposition(
        catchUpState: BackgroundSyncContinuationState? = nil,
        hadFetchFailures: Bool,
        latestHistoryId: String?
    ) -> BackgroundSyncCompletionDisposition {
        if hadFetchFailures {
            return BackgroundSyncCompletionDisposition(
                historyIdToStore: nil,
                continuationState: nil,
                retryAction: .failureBackoff,
                shouldResetRetryState: false
            )
        }

        if let catchUpState {
            return BackgroundSyncCompletionDisposition(
                historyIdToStore: nil,
                continuationState: catchUpState,
                retryAction: .catchUp,
                shouldResetRetryState: false
            )
        }

        return BackgroundSyncCompletionDisposition(
            historyIdToStore: latestHistoryId,
            continuationState: nil,
            retryAction: .none,
            shouldResetRetryState: true
        )
    }

    static func shouldScheduleRetryWhenBlocked(by activeRunKind: SyncRunKind?) -> Bool {
        activeRunKind == nil || activeRunKind == .pendingActions
    }
}
