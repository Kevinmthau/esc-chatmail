import Foundation
import BackgroundTasks

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

    init(
        taskScheduler: any BackgroundTaskScheduling = BackgroundTaskScheduler.shared,
        defaults: UserDefaults = .standard,
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
        self.stateManager = BackgroundSyncStateManager()
        self.defaults = defaults
        self.authoritativeSyncExecutorProvider = authoritativeSyncExecutorProvider
        self.authoritativeSyncReadiness = authoritativeSyncReadiness
        self.authoritativeSyncIsAuthenticated = authoritativeSyncIsAuthenticated
        self.authoritativeSyncIsDurablySignedOut = authoritativeSyncIsDurablySignedOut
        self.beginSceneBackgroundAssertion = beginSceneBackgroundAssertion

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
            // A clean run returns the shared backoff to its initial delay so
            // the next failure does not inherit a spent retry budget.
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

    // MARK: - Retry Scheduling

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

    static func shouldScheduleRetryWhenBlocked(by activeRunKind: SyncRunKind?) -> Bool {
        activeRunKind == nil
            || activeRunKind == .pendingActions
            || activeRunKind == .maintenance
    }
}
