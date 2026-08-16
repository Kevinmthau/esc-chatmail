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

enum BackgroundMailboxSyncBudget: Equatable, Sendable {
    case appRefresh
    case processing

    var historyPageLimit: Int {
        switch self {
        case .appRefresh:
            return SyncConfig.maxHistoryPagesPerAppRefreshSlice
        case .processing:
            return SyncConfig.maxHistoryPagesPerProcessingSlice
        }
    }

    var historyPageSize: Int {
        switch self {
        case .appRefresh:
            return SyncConfig.maxHistoryResultsPerAppRefreshRequest
        case .processing:
            return SyncConfig.maxHistoryResultsPerProcessingRequest
        }
    }

    var allowsExpensiveRecovery: Bool {
        self == .processing
    }
}

/// The model-v3 mailbox sync entry point used by `BGTask` launches. The
/// production implementation owns and cancels the exact incremental run it
/// starts, while tests can exercise the background hand-off without creating
/// `BGTask` instances (which Apple does not expose public initializers for).
@MainActor
protocol BackgroundMailboxSyncExecuting: AnyObject, Sendable {
    func performIncrementalSyncForBackground(
        budget: BackgroundMailboxSyncBudget
    ) async -> BackgroundMailboxSyncExecutionResult
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
    private let authoritativeSyncIsDurablySignedOut: @MainActor @Sendable () -> Bool
    /// Takes a background-execution assertion and returns the closure that
    /// releases it. `armBackgroundTasksForSceneBackground()`'s pending checks
    /// are async, so without the assertion iOS could suspend the process
    /// between the scene transition and the deferred submits, silently losing
    /// the arm for that backgrounding. The default cancels that arm and
    /// releases on UIKit's expiration handler too
    /// (`SceneBackgroundAssertionLatch`) — an unended assertion past its grant
    /// is a watchdog kill, not a suspension.
    private let beginSceneBackgroundAssertion: @MainActor @Sendable (
        _ onExpiration: @escaping @MainActor @Sendable () -> Void
    ) -> (@MainActor @Sendable () -> Void)
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
            AuthSession.shared.canAccessMailbox
        },
        authoritativeSyncIsDurablySignedOut: @escaping @MainActor @Sendable () -> Bool = {
            AuthSession.shared.isDurablySignedOut()
        },
        syncCoordinatorProvider: @escaping @MainActor @Sendable () -> BackgroundSyncMessageCoordinating = {
            SyncEngine.shared
        },
        beginSceneBackgroundAssertion: @escaping @MainActor @Sendable (
            _ onExpiration: @escaping @MainActor @Sendable () -> Void
        ) -> (@MainActor @Sendable () -> Void) = { onExpiration in
            let latch = SceneBackgroundAssertionLatch()
            latch.begin(
                name: "BackgroundSyncManager.armBackgroundTasksForSceneBackground",
                onExpiration: onExpiration
            )
            return { latch.end() }
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
        self.authoritativeSyncIsDurablySignedOut = authoritativeSyncIsDurablySignedOut
        self.beginSceneBackgroundAssertion = beginSceneBackgroundAssertion
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

    /// Arms both background-task requests when the scene enters the background.
    ///
    /// The policy lives here rather than in the scene handler so it stays
    /// spy-testable (the App struct runs under no test plan). Both submits are
    /// guarded because a `BGTaskScheduler` re-submit with a pending identifier
    /// REPLACES the pending request: unguarded scheduling on every
    /// backgrounding postponed the processing task indefinitely (the scene
    /// handler's original bug), and an unguarded refresh re-arm resets a
    /// sooner-dated backoff/catch-up retry sharing the refresh identifier to
    /// the plain 15-minute cadence. Skipping the refresh re-arm never
    /// postpones it: every refresh submit path uses a delay of at most
    /// 15 minutes, so a pending request always begins no later than a fresh
    /// submit would.
    ///
    /// The pending checks are async (`getPendingTaskRequests`), so the submits
    /// no longer complete synchronously inside the scene callback; the
    /// background-execution assertion taken here, before the transition
    /// completes, keeps the process runnable until the arm finishes —
    /// restoring the schedule-before-suspend guarantee the synchronous calls
    /// had.
    @MainActor
    func armBackgroundTasksForSceneBackground() {
        guard canScheduleAuthoritativeSync() else {
            Log.debug("Scene-background arm skipped: cannot access mailbox", category: .background)
            return
        }
        let cancellationLatch = BackgroundTaskCancellationLatch()
        let endAssertion = beginSceneBackgroundAssertion {
            cancellationLatch.expire()
        }
        let armTask = Task {
            defer { endAssertion() }
            guard !Task.isCancelled else { return }
            let refreshPending = await taskScheduler.isAppRefreshTaskPending()
            guard !Task.isCancelled else { return }
            let processingPending = await taskScheduler.isProcessingTaskPending()
            // Re-checked in the same MainActor slice as the submits: sign-out
            // drops the gate and then sweeps pending requests
            // (cancelPendingTaskRequests) while this Task is suspended in the
            // pending fetches, so a submit behind a stale gate would re-arm
            // the wakes that sweep just disarmed. With gate and submits in
            // one suspension-free slice, an arm either wholly precedes the
            // sweep (its submits get swept) or observes the dropped gate and
            // submits nothing.
            guard !Task.isCancelled, canScheduleAuthoritativeSync() else {
                Log.debug("Scene-background arm abandoned during pending checks", category: .background)
                return
            }
            if refreshPending {
                Log.debug("Skipping still-pending refresh request", category: .background)
            } else {
                taskScheduler.scheduleAppRefresh()
            }
            if processingPending {
                Log.debug("Skipping still-pending processing request", category: .background)
            } else {
                taskScheduler.scheduleProcessingTask()
            }
        }
        // The Task inherits MainActor isolation and cannot begin until this
        // synchronous method returns. Installation therefore precedes work;
        // the latch also remembers a test/system expiration delivered while
        // the assertion itself is being created.
        cancellationLatch.install {
            armTask.cancel()
        }
    }

    /// Submits a processing-task request only when none is already pending.
    /// A `BGTaskScheduler` re-submit with the same identifier REPLACES the
    /// pending request and pushes its `earliestBeginDate` another hour out,
    /// so a caller that fires on every scene-background transition would
    /// otherwise postpone the processing task indefinitely.
    ///
    /// Best-effort, not atomic: the pending check and the submit straddle an
    /// await, so concurrent arm attempts can race. A racing re-submit shifts
    /// `earliestBeginDate` only by the race window (each submit re-anchors to
    /// its own "now"), never by the pending request's full interval.
    func scheduleProcessingTaskIfNotPending(
        schedulingGate: BackgroundTaskSchedulingGate? = nil
    ) async {
        guard !Task.isCancelled else { return }
        if await !taskScheduler.isProcessingTaskPending() {
            // Pair the post-await auth/cancellation re-check and submit in one
            // MainActor slice. If sign-out wins first, this submits nothing;
            // if this wins first, sign-out's subsequent cancellation sweeps it.
            // The cancellation check also covers expiration while the pending
            // query or actor hop was suspended.
            await MainActor.run {
                guard !Task.isCancelled, canScheduleAuthoritativeSync() else { return }
                submitIfSchedulingActive(schedulingGate) {
                    taskScheduler.scheduleProcessingTask()
                }
            }
        }
    }

    // MARK: - Task Handlers

    private func handleAppRefresh(task: BGAppRefreshTask) {
        taskScheduler.scheduleAppRefresh()
        runBackgroundTask(task, budget: .appRefresh)
    }

    private func handleProcessing(task: BGProcessingTask) {
        taskScheduler.scheduleProcessingTask()
        runBackgroundTask(task, budget: .processing)
    }

    /// Shared implementation for both app-refresh and processing background
    /// tasks. Completion is exactly once and waits for cancellation cleanup.
    private func runBackgroundTask(_ task: BGTask, budget: BackgroundMailboxSyncBudget) {
        runBackgroundTaskOperation(
            budget: budget,
            installExpirationHandler: { handler in
                task.expirationHandler = handler
            },
            onComplete: { success in
                task.setTaskCompleted(success: success)
            }
        )
    }

    /// Closure-based core keeps the BGTask-only lifecycle ordering directly
    /// testable; Apple exposes no public initializer for its task subclasses.
    func runBackgroundTaskOperation(
        budget: BackgroundMailboxSyncBudget,
        installExpirationHandler: (@escaping () -> Void) -> Void,
        onComplete: @escaping (Bool) -> Void
    ) {
        let lifecycleState = BackgroundTaskLifecycleState()
        let latch = BackgroundTaskCompletionLatch(
            lifecycleState: lifecycleState,
            onComplete: onComplete
        )
        let schedulingGate = BackgroundTaskSchedulingGate(
            lifecycleState: lifecycleState
        )
        let cancellationLatch = BackgroundTaskCancellationLatch()
        let workerStartGate = BackgroundTaskWorkerStartGate()

        // Install expiration before launching the worker. The cancellation
        // latch remembers an expiration that beats worker creation, while the
        // scheduling gate closes immediately on the system callback's thread.
        installExpirationHandler {
            // One atomic transition both rejects later scheduling and forces
            // the worker's eventual completion result to failure.
            lifecycleState.expire()
            cancellationLatch.expire()
        }

        let backgroundTask = Task { [weak self] in
            // `Task` starts eagerly. Do not inspect auth or touch the sync
            // engine until expiration can cancel this exact worker.
            await workerStartGate.waitUntilOpen()
            guard let self = self else {
                return false
            }
            if self.legacyDeltaSyncEnabled {
                return await self.performDeltaSync(isProcessingTask: budget == .processing)
            }
            return await self.performAuthoritativeSync(
                budget: budget,
                schedulingGate: schedulingGate
            )
        }
        cancellationLatch.install {
            backgroundTask.cancel()
        }
        workerStartGate.open()

        // Completion is owned by a separate waiter so it runs only after the
        // cancelled worker (including its durable-sign-out sweep and sync
        // engine cleanup) has actually returned.
        Task {
            let success = await backgroundTask.value
            latch.complete(success: success)
        }
    }

    /// Executes the authoritative model-v3 sync and preserves structured task
    /// cancellation so a `BGTask` expiration reaches the exact underlying run.
    func performAuthoritativeSync(
        budget: BackgroundMailboxSyncBudget = .processing,
        schedulingGate: BackgroundTaskSchedulingGate? = nil
    ) async -> Bool {
        if Task.isCancelled {
            // Handlers re-arm their ordinary cadence before launching the
            // worker. Expiration can cancel that worker before it starts, but
            // a definitively signed-out stale delivery must still sweep the
            // request the handler just submitted.
            await cancelPendingRequestsIfDurablySignedOut()
            return false
        }
        guard await authoritativeSyncReadiness() else {
            // Bootstrap failure is a real failure, not a verdict on the mailbox,
            // so it takes the same bounded backoff as any other failed run. An
            // expired or definitively signed-out task must not queue more work.
            await scheduleReadinessFailureRetryIfRunnable(schedulingGate: schedulingGate)
            return false
        }
        if Task.isCancelled {
            // Readiness can finish after expiration. As at entry, a stale
            // signed-out delivery must still remove the cadence its handler
            // re-armed before launching this worker.
            await cancelPendingRequestsIfDurablySignedOut()
            return false
        }
        let canAccessMailbox = await MainActor.run { () -> Bool in
            let isDurablySignedOut = authoritativeSyncIsDurablySignedOut()
            guard authoritativeSyncIsAuthenticated(), !isDurablySignedOut else {
                // A stale request delivered after logout is a successful no-op.
                // Devices that signed out before #171 are otherwise stuck in a
                // perpetual re-arm chain because handlers re-arm at entry.
                // Only a definitive verdict may self-heal the old request: a
                // transient restore failure must preserve a live cadence.
                if isDurablySignedOut {
                    taskScheduler.cancelPendingTaskRequests()
                }
                return false
            }
            return true
        }
        guard !Task.isCancelled else { return false }
        guard canAccessMailbox else {
            return true
        }

        BackgroundSyncStateManager.clearContinuationState(in: defaults)
        let executor = await MainActor.run { authoritativeSyncExecutorProvider() }
        guard !Task.isCancelled else { return false }
        let result = await executor.performIncrementalSyncForBackground(budget: budget)
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
            if budget == .appRefresh {
                // A short refresh slice should not grow into initial sync or a
                // long catch-up run. Ensure the processing queue has an
                // opportunity to take over while refresh retries remain small.
                // The guarded helper skips the submit while a request is
                // pending — an unguarded re-submit would REPLACE it and push
                // its earliestBeginDate another hour out, so frequent refresh
                // slices would starve the very task this escalation exists
                // to arm.
                await scheduleProcessingTaskIfNotPending(schedulingGate: schedulingGate)
            }
            await scheduleCatchUpRetryIfRunnable(schedulingGate: schedulingGate)
            return false
        case .blocked(let activeKind):
            guard Self.shouldScheduleRetryWhenBlocked(by: activeKind) else {
                return true
            }
            await scheduleCatchUpRetryIfRunnable(schedulingGate: schedulingGate)
            return false
        case .failed:
            // Without this the run reported failure and scheduled nothing, so a
            // transient failure waited out the ordinary 15-minute refresh cadence
            // instead of the bounded exponential backoff every other failure
            // path uses.
            await scheduleFailureBackoffRetryIfRunnable(schedulingGate: schedulingGate)
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

    /// Schedules a bootstrap-failure retry unless expiration or a definitive
    /// sign-out won while readiness was suspended. A transient restore failure
    /// remains retryable even though it has no published authenticated session.
    @MainActor
    private func scheduleReadinessFailureRetryIfRunnable(
        schedulingGate: BackgroundTaskSchedulingGate?
    ) {
        if cancelPendingRequestsIfDurablySignedOut() {
            return
        }
        guard !Task.isCancelled else { return }
        // A transient restore/bootstrap failure remains retryable even without
        // a currently published authenticated session.
        submitIfSchedulingActive(schedulingGate) {
            scheduleFailureBackoffRetry()
        }
    }

    /// Serializes the post-executor auth/cancellation verdict with its submit
    /// against sign-out's MainActor-isolated gate drop and cancellation sweep.
    @MainActor
    private func scheduleFailureBackoffRetryIfRunnable(
        schedulingGate: BackgroundTaskSchedulingGate?
    ) {
        guard !Task.isCancelled, canScheduleAuthoritativeSync() else { return }
        submitIfSchedulingActive(schedulingGate) {
            scheduleFailureBackoffRetry()
        }
    }

    private func scheduleCatchUpRetry() {
        // Catch-up is progress, not failure, so bypass the exponential-backoff
        // retry counter and reschedule on a short fixed delay instead.
        taskScheduler.scheduleRetryAfterBackoff(Self.catchUpRetryDelay)
    }

    /// See `scheduleFailureBackoffRetryIfRunnable(schedulingGate:)`.
    @MainActor
    private func scheduleCatchUpRetryIfRunnable(
        schedulingGate: BackgroundTaskSchedulingGate?
    ) {
        guard !Task.isCancelled, canScheduleAuthoritativeSync() else { return }
        submitIfSchedulingActive(schedulingGate) {
            scheduleCatchUpRetry()
        }
    }

    @MainActor
    private func canScheduleAuthoritativeSync() -> Bool {
        authoritativeSyncIsAuthenticated() && !authoritativeSyncIsDurablySignedOut()
    }

    @MainActor
    @discardableResult
    private func cancelPendingRequestsIfDurablySignedOut() -> Bool {
        guard authoritativeSyncIsDurablySignedOut() else { return false }
        taskScheduler.cancelPendingTaskRequests()
        return true
    }

    @MainActor
    private func submitIfSchedulingActive(
        _ schedulingGate: BackgroundTaskSchedulingGate?,
        submission: () -> Void
    ) {
        if let schedulingGate {
            schedulingGate.submitIfActive(submission)
        } else {
            submission()
        }
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
