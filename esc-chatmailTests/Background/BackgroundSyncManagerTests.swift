import XCTest
import BackgroundTasks
import CoreData
@testable import esc_chatmail

final class BackgroundSyncManagerTests: XCTestCase {
    private static let partialQuery = "after:123 -label:spam -label:drafts -label:trash"

    private var testStack: TestCoreDataStack!
    private var coreDataStack: CoreDataStack!
    private var defaults: UserDefaults!
    private var defaultsSuiteName: String!
    private var apiClient: MockGmailAPIClient!
    private var taskScheduler: BackgroundTaskSchedulerSpy!

    override func setUp() {
        super.setUp()
        testStack = TestCoreDataStack()
        coreDataStack = CoreDataStack(
            persistentContainerForTesting: testStack.persistentContainer
        )
        defaultsSuiteName = "BackgroundSyncManagerTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: defaultsSuiteName)!
        apiClient = MockGmailAPIClient()
        taskScheduler = BackgroundTaskSchedulerSpy()
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: defaultsSuiteName)
        taskScheduler = nil
        apiClient = nil
        defaults = nil
        defaultsSuiteName = nil
        coreDataStack = nil
        testStack = nil
        super.tearDown()
    }

    func testCompletionDisposition_truncationStoresContinuationAndSchedulesCatchUpRetry() {
        let continuationState = BackgroundSyncContinuationState.history(
            startHistoryId: "history-100",
            pageToken: "page-2"
        )
        let disposition = BackgroundSyncManager.completionDisposition(
            catchUpState: continuationState,
            hadFetchFailures: false,
            latestHistoryId: "history-123"
        )

        XCTAssertEqual(
            disposition,
            BackgroundSyncCompletionDisposition(
                historyIdToStore: nil,
                continuationState: continuationState,
                retryAction: .catchUp,
                shouldResetRetryState: false
            )
        )
    }

    func testCompletionDisposition_failuresUseFailureBackoff() {
        let disposition = BackgroundSyncManager.completionDisposition(
            hadFetchFailures: true,
            latestHistoryId: "history-123"
        )

        XCTAssertEqual(
            disposition,
            BackgroundSyncCompletionDisposition(
                historyIdToStore: nil,
                continuationState: nil,
                retryAction: .failureBackoff,
                shouldResetRetryState: false
            )
        )
    }

    func testCompletionDisposition_successAdvancesHistoryIdAndResetsRetryState() {
        let disposition = BackgroundSyncManager.completionDisposition(
            hadFetchFailures: false,
            latestHistoryId: "history-123"
        )

        XCTAssertEqual(
            disposition,
            BackgroundSyncCompletionDisposition(
                historyIdToStore: "history-123",
                continuationState: nil,
                retryAction: .none,
                shouldResetRetryState: true
            )
        )
    }

    func testBlockedBackgroundSync_schedulesRetryOnlyForPendingActions() {
        XCTAssertTrue(
            BackgroundSyncManager.shouldScheduleRetryWhenBlocked(by: .pendingActions)
        )
        XCTAssertFalse(
            BackgroundSyncManager.shouldScheduleRetryWhenBlocked(by: .foregroundIncremental)
        )
        XCTAssertFalse(
            BackgroundSyncManager.shouldScheduleRetryWhenBlocked(by: .background)
        )
        XCTAssertTrue(
            BackgroundSyncManager.shouldScheduleRetryWhenBlocked(by: nil)
        )
    }

    func testModelV3Executor_registersHandlersAndSchedulesBackgroundWork() async {
        let manager = makeManager(legacyDeltaSyncEnabled: false)

        manager.registerBackgroundTasks()
        manager.scheduleAppRefresh()
        await manager.scheduleProcessingTaskIfNotPending()

        XCTAssertEqual(taskScheduler.registrationCount, 1)
        XCTAssertEqual(taskScheduler.appRefreshScheduleCount, 1)
        XCTAssertEqual(taskScheduler.processingScheduleCount, 1)
        XCTAssertNotNil(taskScheduler.onAppRefresh)
        XCTAssertNotNil(taskScheduler.onProcessing)
    }

    func testModelV3Executor_performsAuthoritativeIncrementalSync() async {
        let executor = await MainActor.run {
            BackgroundMailboxSyncExecutorSpy(result: .completed)
        }
        let manager = makeManager(
            legacyDeltaSyncEnabled: false,
            authoritativeSyncExecutor: executor
        )

        let success = await manager.performAuthoritativeSync()

        XCTAssertTrue(success)
        let callCount = await MainActor.run { executor.callCount }
        XCTAssertEqual(callCount, 1)
    }

    // Revert-check: fails if `performAuthoritativeSync(budget:)` stops forwarding its
    // budget into `performIncrementalSyncForBackground(budget:)` (the recorded pair
    // collapses to one value), or if `BackgroundMailboxSyncBudget.appRefresh` stops
    // mapping to the short-slice constants and returns the processing/foreground
    // 10/500/allowsExpensiveRecovery values instead.
    func testModelV3Executor_passesDistinctAppRefreshAndProcessingBudgets() async {
        let executor = await MainActor.run {
            BackgroundMailboxSyncExecutorSpy(result: .completed)
        }
        let manager = makeManager(
            legacyDeltaSyncEnabled: false,
            authoritativeSyncExecutor: executor
        )

        _ = await manager.performAuthoritativeSync(budget: .appRefresh)
        _ = await manager.performAuthoritativeSync(budget: .processing)

        let budgets = await MainActor.run { executor.budgets }
        XCTAssertEqual(budgets, [.appRefresh, .processing])
        XCTAssertEqual(budgets.map(\.historyPageLimit), [3, 10])
        XCTAssertEqual(budgets.map(\.historyPageSize), [100, 500])
        XCTAssertFalse(BackgroundMailboxSyncBudget.appRefresh.allowsExpensiveRecovery)
        XCTAssertTrue(BackgroundMailboxSyncBudget.processing.allowsExpensiveRecovery)
    }

    func testModelV3Executor_incompleteHistorySchedulesCatchUpAndFailsTask() async {
        let executor = await MainActor.run {
            BackgroundMailboxSyncExecutorSpy(result: .needsFollowUp)
        }
        let manager = makeManager(
            legacyDeltaSyncEnabled: false,
            authoritativeSyncExecutor: executor
        )

        let success = await manager.performAuthoritativeSync()

        XCTAssertFalse(success)
        XCTAssertEqual(taskScheduler.retryBackoffs, [BackgroundSyncManager.catchUpRetryDelay])
    }

    // Revert-check: fails if the `budget == .appRefresh` branch that calls
    // `taskScheduler.scheduleProcessingTask()` is dropped from the `.needsFollowUp`
    // case of `performAuthoritativeSync()`. A deferred short slice would then only
    // re-arm the catch-up retry and never hand the backlog to a processing task,
    // so an app-refresh-only device could never drain a deferred initial sync.
    func testModelV3Executor_appRefreshFollowUpEscalatesToProcessingTask() async {
        let executor = await MainActor.run {
            BackgroundMailboxSyncExecutorSpy(result: .needsFollowUp)
        }
        let manager = makeManager(
            legacyDeltaSyncEnabled: false,
            authoritativeSyncExecutor: executor
        )

        let success = await manager.performAuthoritativeSync(budget: .appRefresh)

        XCTAssertFalse(success)
        XCTAssertEqual(taskScheduler.processingScheduleCount, 1)
        XCTAssertEqual(taskScheduler.retryBackoffs, [BackgroundSyncManager.catchUpRetryDelay])
    }

    // Revert-check: fails if the escalation branch stops consulting
    // `taskScheduler.isProcessingTaskPending()` before re-submitting. A BGTask
    // re-submit with the same identifier REPLACES the pending request and
    // pushes its earliestBeginDate another hour out, so app-refresh slices
    // arriving more often than hourly would starve the processing task forever.
    func testModelV3Executor_appRefreshFollowUpDoesNotReplacePendingProcessingTask() async {
        let executor = await MainActor.run {
            BackgroundMailboxSyncExecutorSpy(result: .needsFollowUp)
        }
        let manager = makeManager(
            legacyDeltaSyncEnabled: false,
            authoritativeSyncExecutor: executor
        )
        taskScheduler.processingTaskPending = true

        let success = await manager.performAuthoritativeSync(budget: .appRefresh)

        XCTAssertFalse(success)
        XCTAssertEqual(
            taskScheduler.processingScheduleCount,
            0,
            "A pending processing request must not be replaced (and thereby postponed)"
        )
        XCTAssertEqual(taskScheduler.retryBackoffs, [BackgroundSyncManager.catchUpRetryDelay])
    }

    // Revert-check: fails if `BackgroundSyncManager.scheduleProcessingTaskIfNotPending()`
    // stops consulting `taskScheduler.isProcessingTaskPending()` and submits
    // unconditionally — the regression the scene-background call site in
    // `esc_chatmailApp.handleScenePhaseChange` had before it was guarded. A
    // BGTask re-submit with the same identifier REPLACES the pending request
    // and pushes its earliestBeginDate another hour out, so backgrounding the
    // app more often than hourly postponed the processing task indefinitely.
    // (The unguarded manager-level pass-through no longer exists, so reverting
    // the call site itself fails to compile rather than silently regressing.)
    func testScheduleProcessingTaskIfNotPending_doesNotReplacePendingRequest() async {
        let manager = makeManager(legacyDeltaSyncEnabled: false)
        taskScheduler.processingTaskPending = true

        await manager.scheduleProcessingTaskIfNotPending()

        XCTAssertEqual(
            taskScheduler.processingScheduleCount,
            0,
            "A pending processing request must not be replaced (and thereby postponed)"
        )
    }

    // Companion to the pending-request test above: proves the guard is a guard,
    // not a no-op, so the pair together pins both sides of the branch.
    func testScheduleProcessingTaskIfNotPending_submitsWhenNoRequestIsPending() async {
        let manager = makeManager(legacyDeltaSyncEnabled: false)

        await manager.scheduleProcessingTaskIfNotPending()

        XCTAssertEqual(taskScheduler.processingScheduleCount, 1)
    }

    // Revert-check: fails if `BackgroundSyncManager.scheduleFailureBackoffRetry()`
    // is removed from the `.failed` case of `performAuthoritativeSync()`.
    // A failed background run must take the same bounded exponential backoff the
    // legacy delta path took via `.failureBackoff`, not silently wait out the
    // ordinary 15-minute refresh cadence.
    func testModelV3Executor_failedSyncSchedulesFailureBackoffRetry() async {
        let executor = await MainActor.run {
            BackgroundMailboxSyncExecutorSpy(result: .failed)
        }
        let manager = makeManager(
            legacyDeltaSyncEnabled: false,
            authoritativeSyncExecutor: executor
        )

        let success = await manager.performAuthoritativeSync()

        XCTAssertFalse(success)
        // First strike doubles the 30s initial backoff.
        XCTAssertEqual(taskScheduler.retryBackoffs, [60])
    }

    // Revert-check: fails if `scheduleFailureBackoffRetry()` stops routing through
    // `BackgroundSyncStateManager.incrementRetryAndGetBackoff()` (e.g. is replaced
    // by a fixed delay), which would lose the escalation and the skipped slot.
    // Pins the rolling three-failure window: 60s, 120s, skip, and repeat — the
    // counter resets on the skipped slot rather than terminating.
    func testModelV3Executor_failureBackoffCyclesEveryThirdConsecutiveRetry() async {
        let executor = await MainActor.run {
            BackgroundMailboxSyncExecutorSpy(result: .failed)
        }
        let manager = makeManager(
            legacyDeltaSyncEnabled: false,
            authoritativeSyncExecutor: executor
        )

        for _ in 0..<6 {
            _ = await manager.performAuthoritativeSync()
        }

        // 30s initial backoff doubles twice; the third consecutive strike skips
        // scheduling and resets, so the cycle restarts rather than escalating.
        XCTAssertEqual(taskScheduler.retryBackoffs, [60, 120, 60, 120])
    }

    // Revert-check: fails if `stateManager.resetRetryCount()` is removed from the
    // `.completed` case of `performAuthoritativeSync()`. Without it the trailing
    // failure below exhausts the retry budget and schedules nothing.
    func testModelV3Executor_completedSyncResetsFailureBackoff() async {
        let executor = await MainActor.run {
            SequencedBackgroundMailboxSyncExecutorSpy(
                results: [.failed, .failed, .completed, .failed]
            )
        }
        let manager = makeManager(
            legacyDeltaSyncEnabled: false,
            authoritativeSyncExecutor: executor
        )

        for _ in 0..<4 {
            _ = await manager.performAuthoritativeSync()
        }

        // The clean run returns the backoff to its initial delay, so the trailing
        // failure starts over at 60 instead of falling off the exhausted budget.
        XCTAssertEqual(taskScheduler.retryBackoffs, [60, 120, 60])
    }

    // Revert-check: fails if the readiness-failure branch of
    // `performAuthoritativeSync()` stops calling `scheduleFailureBackoffRetry()`.
    func testModelV3Executor_bootstrapFailureSchedulesFailureBackoffRetry() async {
        let executor = await MainActor.run {
            BackgroundMailboxSyncExecutorSpy(result: .completed)
        }
        let manager = makeManager(
            legacyDeltaSyncEnabled: false,
            authoritativeSyncExecutor: executor,
            authoritativeSyncReadiness: { false }
        )

        let success = await manager.performAuthoritativeSync()

        XCTAssertFalse(success)
        XCTAssertEqual(taskScheduler.retryBackoffs, [60])
        let callCount = await MainActor.run { executor.callCount }
        XCTAssertEqual(callCount, 0)
    }

    func testModelV3Executor_waitsForPersistenceBootstrapBeforeSyncing() async {
        let executor = await MainActor.run {
            BackgroundMailboxSyncExecutorSpy(result: .completed)
        }
        let readinessGate = BackgroundSyncReadinessGate()
        let manager = makeManager(
            legacyDeltaSyncEnabled: false,
            authoritativeSyncExecutor: executor,
            authoritativeSyncReadiness: {
                await readinessGate.waitUntilReleased()
            }
        )
        let syncTask = Task {
            await manager.performAuthoritativeSync()
        }
        await readinessGate.waitUntilStarted()

        let callCountBeforeReadiness = await MainActor.run { executor.callCount }
        XCTAssertEqual(callCountBeforeReadiness, 0)

        await readinessGate.release(succeeded: true)
        let success = await syncTask.value
        XCTAssertTrue(success)
        let finalCallCount = await MainActor.run { executor.callCount }
        XCTAssertEqual(finalCallCount, 1)
    }

    func testModelV3Executor_bootstrapFailureDoesNotTouchSyncEngine() async {
        let executor = await MainActor.run {
            BackgroundMailboxSyncExecutorSpy(result: .completed)
        }
        let manager = makeManager(
            legacyDeltaSyncEnabled: false,
            authoritativeSyncExecutor: executor,
            authoritativeSyncReadiness: { false }
        )

        let success = await manager.performAuthoritativeSync()

        XCTAssertFalse(success)
        let callCount = await MainActor.run { executor.callCount }
        XCTAssertEqual(callCount, 0)
    }

    func testModelV3Executor_unauthenticatedAfterBootstrapSkipsSyncAsSuccessfulNoOp() async {
        let executor = await MainActor.run {
            BackgroundMailboxSyncExecutorSpy(result: .completed)
        }
        let manager = makeManager(
            legacyDeltaSyncEnabled: false,
            authoritativeSyncExecutor: executor,
            authoritativeSyncIsAuthenticated: { false }
        )

        let success = await manager.performAuthoritativeSync()

        XCTAssertTrue(success)
        let callCount = await MainActor.run { executor.callCount }
        XCTAssertEqual(callCount, 0)
    }

    func testStartupBootstrap_coalescesConcurrentPersistencePreparation() async {
        let readinessGate = BackgroundSyncReadinessGate()
        let bootstrap = AppStartupBootstrap(
            preparePersistenceOperation: {
                await readinessGate.waitUntilReleased()
            }
        )
        let first = Task { await bootstrap.preparePersistenceIfNeeded() }
        await readinessGate.waitUntilStarted()
        let second = Task { await bootstrap.preparePersistenceIfNeeded() }

        for _ in 0..<20 {
            await Task.yield()
        }
        let invocationCountWhileBlocked = await readinessGate.invocationCount()
        XCTAssertEqual(invocationCountWhileBlocked, 1)

        await readinessGate.release(succeeded: true)
        let firstResult = await first.value
        let secondResult = await second.value
        XCTAssertTrue(firstResult)
        XCTAssertTrue(secondResult)

        let cachedResult = await bootstrap.preparePersistenceIfNeeded()
        XCTAssertTrue(cachedResult)
        let finalInvocationCount = await readinessGate.invocationCount()
        XCTAssertEqual(finalInvocationCount, 1)
    }

    func testStartupBootstrap_failedPersistencePreparationRetries() async {
        let preparationScript = BackgroundPersistencePreparationScript(
            outcomes: [false, true]
        )
        let bootstrap = AppStartupBootstrap(
            preparePersistenceOperation: {
                await preparationScript.prepare()
            }
        )

        let firstResult = await bootstrap.preparePersistenceIfNeeded()
        let retryResult = await bootstrap.preparePersistenceIfNeeded()
        let cachedResult = await bootstrap.preparePersistenceIfNeeded()

        XCTAssertFalse(firstResult)
        XCTAssertTrue(retryResult)
        XCTAssertTrue(cachedResult)
        let invocationCount = await preparationScript.invocationCount()
        XCTAssertEqual(invocationCount, 2)
    }

    func testStartupBootstrap_foregroundRetriesAfterJoinedBackgroundPreparationFails() async {
        let firstAttemptGate = BackgroundSyncReadinessGate()
        let preparationScript = BackgroundPersistencePreparationScript(
            outcomes: [false, true]
        )
        let bootstrap = AppStartupBootstrap(
            preparePersistenceOperation: {
                let result = await preparationScript.prepare()
                if result == false {
                    return await firstAttemptGate.waitUntilReleased()
                }
                return result
            }
        )

        let background = Task { await bootstrap.preparePersistenceIfNeeded() }
        await firstAttemptGate.waitUntilStarted()
        let foreground = Task {
            await bootstrap.preparePersistenceUntilReady(retryDelayNanoseconds: 0)
        }

        for _ in 0..<20 {
            await Task.yield()
        }
        let invocationCountWhileJoined = await preparationScript.invocationCount()
        XCTAssertEqual(
            invocationCountWhileJoined,
            1,
            "Foreground startup should join the in-flight background preparation"
        )

        await firstAttemptGate.release(succeeded: false)

        let backgroundResult = await background.value
        let foregroundResult = await foreground.value
        XCTAssertFalse(backgroundResult)
        XCTAssertTrue(
            foregroundResult,
            "Foreground startup must retry instead of leaving AppLoadingView stuck"
        )
        let finalInvocationCount = await preparationScript.invocationCount()
        XCTAssertEqual(finalInvocationCount, 2)
    }

    func testStartupBootstrap_cancelledPersistenceWaiterReleasesWithoutCancellingSharedPreparation() async {
        let readinessGate = BackgroundSyncReadinessGate()
        let bootstrap = AppStartupBootstrap(
            preparePersistenceOperation: {
                await readinessGate.waitUntilReleased()
            }
        )
        let background = Task { await bootstrap.preparePersistenceIfNeeded() }
        await readinessGate.waitUntilStarted()

        background.cancel()
        let cancelledResult: Bool? = await withSoftTimeout(seconds: 1) {
            await background.value
        }

        XCTAssertEqual(
            cancelledResult,
            false,
            "An expired background caller must stop waiting before shared preparation finishes"
        )

        let foreground = Task { await bootstrap.preparePersistenceIfNeeded() }
        for _ in 0..<20 {
            await Task.yield()
        }
        let invocationCountWhileBlocked = await readinessGate.invocationCount()
        XCTAssertEqual(
            invocationCountWhileBlocked,
            1,
            "The foreground caller must join the preparation left running by cancellation"
        )

        await readinessGate.release(succeeded: true)
        let foregroundResult = await foreground.value
        XCTAssertTrue(foregroundResult)
        let finalInvocationCount = await readinessGate.invocationCount()
        XCTAssertEqual(finalInvocationCount, 1)
    }

    func testStartupBootstrap_coalescesForegroundAndBackgroundAuthenticationRestore() async {
        let authenticationGate = BackgroundSyncReadinessGate()
        let bootstrap = AppStartupBootstrap(
            preparePersistenceOperation: { true },
            restoreAuthenticationOperation: {
                _ = await authenticationGate.waitUntilReleased()
                return .authenticated
            }
        )
        let background = Task { await bootstrap.prepareForBackgroundSync() }
        await authenticationGate.waitUntilStarted()
        let foreground = Task { await bootstrap.restoreAuthenticationIfNeeded() }

        for _ in 0..<20 {
            await Task.yield()
        }
        let invocationCountWhileBlocked = await authenticationGate.invocationCount()
        XCTAssertEqual(invocationCountWhileBlocked, 1)

        await authenticationGate.release(succeeded: true)
        let backgroundResult = await background.value
        let foregroundResult = await foreground.value
        XCTAssertTrue(backgroundResult)
        XCTAssertTrue(foregroundResult)
        let finalInvocationCount = await authenticationGate.invocationCount()
        XCTAssertEqual(finalInvocationCount, 1)
    }

    func testStartupBootstrap_cancelledBackgroundWaiterPreservesSharedRestoreForForeground() async {
        let authenticationGate = BackgroundSyncReadinessGate()
        let bootstrap = AppStartupBootstrap(
            preparePersistenceOperation: { true },
            restoreAuthenticationOperation: {
                _ = await authenticationGate.waitUntilReleased()
                return .authenticated
            }
        )
        let background = Task { await bootstrap.prepareForBackgroundSync() }
        await authenticationGate.waitUntilStarted()

        background.cancel()
        let cancelledResult: Bool? = await withSoftTimeout(seconds: 1) {
            await background.value
        }

        XCTAssertEqual(
            cancelledResult,
            false,
            "An expired BGTask caller must stop waiting before shared auth restore finishes"
        )

        let foreground = Task { await bootstrap.restoreAuthenticationIfNeeded() }
        for _ in 0..<20 {
            await Task.yield()
        }
        let invocationCountWhileBlocked = await authenticationGate.invocationCount()
        XCTAssertEqual(
            invocationCountWhileBlocked,
            1,
            "Foreground startup must join, rather than restart, the shared auth restore"
        )

        await authenticationGate.release(succeeded: true)
        let foregroundResult = await foreground.value
        XCTAssertTrue(foregroundResult)
        let finalInvocationCount = await authenticationGate.invocationCount()
        XCTAssertEqual(finalInvocationCount, 1)
    }

    func testStartupBootstrap_backgroundTransientRestoreRemainsReadyAndForegroundRetries() async {
        let restoreScript = BackgroundAuthenticationRestoreScript(
            outcomes: [.retryableFailure, .authenticated]
        )
        let bootstrap = AppStartupBootstrap(
            preparePersistenceOperation: { true },
            restoreAuthenticationOperation: {
                await restoreScript.restore()
            }
        )

        let backgroundResult = await bootstrap.prepareForBackgroundSync()

        XCTAssertTrue(
            backgroundResult,
            "A transient auth restore must not turn persistence readiness into a loading-screen failure"
        )
        let callsAfterBackground = await restoreScript.invocationCount()
        XCTAssertEqual(callsAfterBackground, 1)

        let foregroundResult = await bootstrap.restoreAuthenticationIfNeeded()

        XCTAssertTrue(foregroundResult)
        let callsAfterForeground = await restoreScript.invocationCount()
        XCTAssertEqual(
            callsAfterForeground,
            2,
            "The background attempt's retryable result must not be memoized"
        )

        let cachedResult = await bootstrap.restoreAuthenticationIfNeeded()
        XCTAssertTrue(cachedResult)
        let finalInvocationCount = await restoreScript.invocationCount()
        XCTAssertEqual(finalInvocationCount, 2)
    }

    func testModelV3Executor_propagatesFailureToBackgroundCompletion() async {
        let executor = await MainActor.run {
            BackgroundMailboxSyncExecutorSpy(result: .failed)
        }
        let manager = makeManager(
            legacyDeltaSyncEnabled: false,
            authoritativeSyncExecutor: executor
        )

        let success = await manager.performAuthoritativeSync()

        XCTAssertFalse(success)
    }

    func testModelV3Executor_pendingActionsBlockSchedulesCatchUpAndFailsTask() async {
        let executor = await MainActor.run {
            BackgroundMailboxSyncExecutorSpy(result: .blocked(by: .pendingActions))
        }
        let manager = makeManager(
            legacyDeltaSyncEnabled: false,
            authoritativeSyncExecutor: executor
        )

        let success = await manager.performAuthoritativeSync()

        XCTAssertFalse(success)
        XCTAssertEqual(taskScheduler.retryBackoffs, [BackgroundSyncManager.catchUpRetryDelay])
    }

    func testModelV3Executor_quiescenceBlockSchedulesCatchUpAndFailsTask() async {
        let executor = await MainActor.run {
            BackgroundMailboxSyncExecutorSpy(result: .blocked(by: nil))
        }
        let manager = makeManager(
            legacyDeltaSyncEnabled: false,
            authoritativeSyncExecutor: executor
        )

        let success = await manager.performAuthoritativeSync()

        XCTAssertFalse(success)
        XCTAssertEqual(taskScheduler.retryBackoffs, [BackgroundSyncManager.catchUpRetryDelay])
    }

    func testModelV3Executor_activeMailboxSyncSatisfiesTaskWithoutCatchUp() async {
        for activeKind in [SyncRunKind.foregroundInitial, .foregroundIncremental, .background] {
            taskScheduler = BackgroundTaskSchedulerSpy()
            let executor = await MainActor.run {
                BackgroundMailboxSyncExecutorSpy(result: .blocked(by: activeKind))
            }
            let manager = makeManager(
                legacyDeltaSyncEnabled: false,
                authoritativeSyncExecutor: executor
            )

            let success = await manager.performAuthoritativeSync()

            XCTAssertTrue(success, "Expected \(activeKind.rawValue) to satisfy background mailbox sync")
            XCTAssertTrue(taskScheduler.retryBackoffs.isEmpty)
        }
    }

    func testModelV3Executor_cancellationPropagatesToAuthoritativeRun() async {
        let executor = await MainActor.run {
            CancellableBackgroundMailboxSyncExecutorSpy()
        }
        let manager = makeManager(
            legacyDeltaSyncEnabled: false,
            authoritativeSyncExecutor: executor
        )
        let task = Task {
            await manager.performAuthoritativeSync()
        }
        await executor.waitUntilStarted()

        task.cancel()
        let success = await task.value

        XCTAssertFalse(success)
        let wasCancelled = await MainActor.run { executor.wasCancelled }
        XCTAssertTrue(wasCancelled)
        // Revert-check: fails if the `guard !Task.isCancelled` that precedes the
        // result switch in `performAuthoritativeSync()` is removed. That guard
        // became load-bearing once `.failed` started scheduling a retry: an
        // expired BGTask maps cancellation to `.failed`, so without it the run
        // would submit a BGTaskRequest after `setTaskCompleted` already fired.
        XCTAssertTrue(
            taskScheduler.retryBackoffs.isEmpty,
            "An expired BGTask must not submit a new BGTaskRequest"
        )
    }

    // Revert-check: fails if the `if !Task.isCancelled` wrapper around
    // `scheduleFailureBackoffRetry()` in the readiness-failure branch of
    // `performAuthoritativeSync()` is removed. Cancellation arriving *during* the
    // readiness suspension is not reachable from the leading cancellation guard.
    func testModelV3Executor_cancelledBootstrapDoesNotScheduleFailureBackoffRetry() async {
        let executor = await MainActor.run {
            BackgroundMailboxSyncExecutorSpy(result: .completed)
        }
        let readinessGate = BackgroundSyncReadinessGate()
        let manager = makeManager(
            legacyDeltaSyncEnabled: false,
            authoritativeSyncExecutor: executor,
            authoritativeSyncReadiness: {
                await readinessGate.waitUntilReleased()
            }
        )
        let task = Task {
            await manager.performAuthoritativeSync()
        }
        await readinessGate.waitUntilStarted()

        task.cancel()
        await readinessGate.release(succeeded: false)
        let success = await task.value

        XCTAssertFalse(success)
        XCTAssertTrue(
            taskScheduler.retryBackoffs.isEmpty,
            "A bootstrap abandoned by task expiry must not queue more work"
        )
        let callCount = await MainActor.run { executor.callCount }
        XCTAssertEqual(callCount, 0)
    }

    func testLegacyGateOn_preservesSchedulingForCharacterizationTests() async {
        let manager = makeManager(legacyDeltaSyncEnabled: true)

        manager.scheduleAppRefresh()
        await manager.scheduleProcessingTaskIfNotPending()

        XCTAssertEqual(taskScheduler.appRefreshScheduleCount, 1)
        XCTAssertEqual(taskScheduler.processingScheduleCount, 1)
    }

    // Revert-check: fails if `BackgroundSyncManager.handleHistorySyncError`'s
    // `APIError.invalidHistoryPageToken` branch stops clearing the persisted continuation
    // and replaying once from the frozen cursor (success flips to a retry-scheduling abort).
    func testLegacyHistorySync_rejectedPersistedPageTokenReplaysOnceFromSavedCursor() async throws {
        let stateManager = makeStateManager()
        try await stateManager.storeHistoryId(
            "history-100",
            accountEmail: "user@example.com"
        )
        try stateManager.storeContinuationState(
            .history(
                startHistoryId: "history-100",
                pageToken: "stale-token",
                accountEmail: "user@example.com"
            )
        )
        apiClient.listHistoryErrorsByPageToken["stale-token"] = APIError.invalidHistoryPageToken
        apiClient.historyResponse = HistoryResponse(
            history: nil,
            nextPageToken: nil,
            historyId: "history-200"
        )

        let success = await makeManager().performHistorySync(
            startHistoryId: "history-100",
            initialPageToken: "stale-token",
            isProcessingTask: false,
            accountEmail: "user@example.com"
        )

        XCTAssertTrue(success)
        XCTAssertEqual(apiClient.listHistoryCalls.map(\.pageToken), ["stale-token", nil])
        XCTAssertNil(stateManager.getContinuationState())
        let storedHistoryId = await stateManager.getStoredHistoryId()
        XCTAssertEqual(storedHistoryId, "history-200")
    }

    // Revert-check: fails if the replay stops passing `initialPageToken: nil` into
    // `performHistorySync` — the guard could then fire again for the same run and issue
    // more than the two pinned `listHistory` calls instead of scheduling a retry.
    func testLegacyHistorySync_repeatedInvalidPageTokenStopsAfterSingleReplay() async throws {
        let stateManager = makeStateManager()
        let continuation = BackgroundSyncContinuationState.history(
            startHistoryId: "history-100",
            pageToken: "stale-token",
            accountEmail: "user@example.com"
        )
        try stateManager.storeContinuationState(continuation)
        apiClient.listHistoryErrorsByPageToken["stale-token"] = APIError.invalidHistoryPageToken
        apiClient.listHistoryError = APIError.invalidHistoryPageToken

        let success = await makeManager().performHistorySync(
            startHistoryId: "history-100",
            initialPageToken: "stale-token",
            isProcessingTask: false,
            accountEmail: "user@example.com"
        )

        XCTAssertFalse(success)
        XCTAssertEqual(apiClient.listHistoryCalls.map(\.pageToken), ["stale-token", nil])
        XCTAssertNil(stateManager.getContinuationState())
        XCTAssertEqual(taskScheduler.retryBackoffs, [60])
    }

    // HONEST SCOPE: this test survives a full revert of the recovery branch — it pins the
    // guard's *scope*, failing only if the `invalidHistoryPageToken` match broadens so an
    // unrelated abort also discards the persisted continuation token.
    func testLegacyHistorySync_unrelatedAbortDoesNotDiscardPersistedPageToken() async throws {
        let stateManager = makeStateManager()
        let continuation = BackgroundSyncContinuationState.history(
            startHistoryId: "history-100",
            pageToken: "stale-token",
            accountEmail: "user@example.com"
        )
        try stateManager.storeContinuationState(continuation)
        apiClient.listHistoryErrorsByPageToken["stale-token"] = APIError.invalidData("bad response")

        let success = await makeManager().performHistorySync(
            startHistoryId: "history-100",
            initialPageToken: "stale-token",
            isProcessingTask: false,
            accountEmail: "user@example.com"
        )

        XCTAssertFalse(success)
        XCTAssertEqual(apiClient.listHistoryCalls.map(\.pageToken), ["stale-token"])
        XCTAssertEqual(stateManager.getContinuationState(), continuation)
        XCTAssertEqual(taskScheduler.retryBackoffs, [60])
    }

    func testHistoryContinuationCompatibility_requiresMatchingAccountAndCursor() {
        let continuationState = BackgroundSyncContinuationState.history(
            startHistoryId: "history-100",
            pageToken: "page-2",
            accountEmail: "user@example.com"
        )

        XCTAssertTrue(
            continuationState.isCompatible(
                storedHistoryId: "history-100",
                currentAccountEmail: "user@example.com"
            )
        )
        XCTAssertFalse(
            continuationState.isCompatible(
                storedHistoryId: "history-101",
                currentAccountEmail: "user@example.com"
            )
        )
        XCTAssertFalse(
            continuationState.isCompatible(
                storedHistoryId: "history-100",
                currentAccountEmail: "other@example.com"
            )
        )
    }

    func testPartialContinuationCompatibility_requiresSameAccountAndSourceCursor() {
        let continuationState = BackgroundSyncContinuationState.partial(
            query: "after:123 -label:spam",
            pageToken: "page-2",
            maxResults: 50,
            startHistoryId: "history-expired",
            watermarkHistoryId: "history-watermark",
            accountEmail: "user@example.com"
        )

        XCTAssertTrue(
            continuationState.isCompatible(
                storedHistoryId: "history-expired",
                currentAccountEmail: "user@example.com"
            )
        )
        XCTAssertFalse(
            continuationState.isCompatible(
                storedHistoryId: "history-advanced",
                currentAccountEmail: "user@example.com"
            )
        )
        XCTAssertFalse(
            continuationState.isCompatible(
                storedHistoryId: "history-expired",
                currentAccountEmail: "other@example.com"
            )
        )

        let initialSyncContinuation = BackgroundSyncContinuationState.partial(
            query: "after:123 -label:spam",
            pageToken: nil,
            maxResults: 50,
            startHistoryId: nil,
            watermarkHistoryId: "history-watermark",
            accountEmail: "user@example.com"
        )
        XCTAssertTrue(
            initialSyncContinuation.isCompatible(
                storedHistoryId: nil,
                currentAccountEmail: "user@example.com"
            )
        )
    }

    func testContinuationCompatibility_rejectsUnscopedState() {
        let continuationState = BackgroundSyncContinuationState.partial(
            query: "after:123 -label:spam",
            pageToken: "page-2",
            maxResults: 50,
            startHistoryId: nil,
            watermarkHistoryId: "history-watermark"
        )

        XCTAssertFalse(
            continuationState.isCompatible(
                storedHistoryId: nil,
                currentAccountEmail: "user@example.com"
            )
        )
    }

    // MARK: - Partial-sync watermark integration

    func testPartialSync_capturesWatermarkBeforeListingAndStoresCanonicalProfileEmail() async throws {
        apiClient.profileResponse = makeProfile(
            email: "Canonical.User@example.com",
            historyId: "history-watermark"
        )
        apiClient.listMessagesResponse = emptyMessagePage(nextPageToken: nil)

        let success = await makeManager().performPartialSync(
            query: Self.partialQuery,
            startHistoryId: nil,
            isProcessingTask: false,
            accountEmail: "canonical.user@EXAMPLE.COM"
        )

        XCTAssertTrue(success)
        XCTAssertEqual(apiClient.endpointCallOrder, ["getProfile", "listMessages"])
        XCTAssertEqual(apiClient.getProfileCallCount, 1)
        XCTAssertEqual(apiClient.listMessagesCallCount, 1)
        XCTAssertNil(makeStateManager().getContinuationState())

        let accounts = try await fetchAccountSnapshots()
        XCTAssertEqual(accounts.count, 1)
        XCTAssertEqual(accounts.first?.email, "Canonical.User@example.com")
        XCTAssertEqual(accounts.first?.historyId, "history-watermark")
    }

    func testPartialSync_rejectsMismatchedProfileAccountBeforeListingOrCheckpointing() async throws {
        apiClient.profileResponse = makeProfile(
            email: "canonical@example.com",
            historyId: "history-watermark"
        )
        apiClient.listMessagesResponse = emptyMessagePage(nextPageToken: nil)

        let success = await makeManager().performPartialSync(
            query: Self.partialQuery,
            startHistoryId: nil,
            isProcessingTask: false,
            accountEmail: "different@example.com"
        )

        XCTAssertFalse(success)
        XCTAssertEqual(apiClient.endpointCallOrder, ["getProfile"])
        XCTAssertEqual(apiClient.listMessagesCallCount, 0)
        XCTAssertNil(makeStateManager().getContinuationState())
        let accounts = try await fetchAccountSnapshots()
        XCTAssertTrue(accounts.isEmpty)
    }

    func testPartialSync_listFailureRetainsInitialCheckpointCapturedBeforeEnumeration() async throws {
        try await makeStateManager().storeHistoryId(
            "history-expired",
            accountEmail: "user@example.com"
        )
        apiClient.profileResponse = makeProfile(
            email: "user@example.com",
            historyId: "history-watermark"
        )
        apiClient.listMessagesError = APIError.timeout

        let manager = makeManager()
        let success = await manager.performPartialSync(
            query: Self.partialQuery,
            startHistoryId: "history-expired",
            isProcessingTask: false,
            accountEmail: "user@example.com"
        )

        XCTAssertFalse(success)
        XCTAssertEqual(apiClient.endpointCallOrder, ["getProfile", "listMessages"])
        XCTAssertEqual(
            makeStateManager().getContinuationState(),
            BackgroundSyncContinuationState.partial(
                query: Self.partialQuery,
                pageToken: nil,
                maxResults: 50,
                startHistoryId: "history-expired",
                watermarkHistoryId: "history-watermark",
                accountEmail: "user@example.com"
            )
        )
        let storedHistoryId = await makeStateManager().getStoredHistoryId()
        XCTAssertEqual(storedHistoryId, "history-expired")

        let checkpoint = try XCTUnwrap(makeStateManager().getContinuationState())
        let checkpointQuery = try XCTUnwrap(checkpoint.query)
        let checkpointMaxResults = try XCTUnwrap(checkpoint.maxResults)
        let checkpointWatermark = try XCTUnwrap(checkpoint.watermarkHistoryId)
        apiClient.profileResponse = makeProfile(
            email: "user@example.com",
            historyId: "history-must-not-be-used"
        )
        apiClient.listMessagesResponse = emptyMessagePage(nextPageToken: nil)

        let retrySucceeded = await manager.performPartialSync(
            query: checkpointQuery,
            initialPageToken: checkpoint.pageToken,
            maxResults: checkpointMaxResults,
            startHistoryId: checkpoint.startHistoryId,
            watermarkHistoryId: checkpointWatermark,
            isProcessingTask: false,
            accountEmail: checkpoint.accountEmail
        )

        XCTAssertTrue(retrySucceeded)
        XCTAssertEqual(apiClient.getProfileCallCount, 1)
        XCTAssertEqual(apiClient.endpointCallOrder, ["getProfile", "listMessages", "listMessages"])
        let retriedHistoryId = await makeStateManager().getStoredHistoryId()
        XCTAssertEqual(retriedHistoryId, "history-watermark")
        XCTAssertNil(makeStateManager().getContinuationState())
    }

    func testPartialSync_messageFetchFailureRetainsOriginalCheckpointAndWatermark() async throws {
        try await makeStateManager().storeHistoryId(
            "history-expired",
            accountEmail: "user@example.com"
        )
        apiClient.profileResponse = makeProfile(
            email: "user@example.com",
            historyId: "history-watermark"
        )
        apiClient.listMessagesResponse = MessagesListResponse(
            messages: [MessageListItem(id: "message-1", threadId: "thread-1")],
            nextPageToken: nil,
            resultSizeEstimate: 1
        )
        apiClient.getMessageError = APIError.timeout

        let success = await makeManager().performPartialSync(
            query: Self.partialQuery,
            startHistoryId: "history-expired",
            isProcessingTask: false,
            accountEmail: "user@example.com"
        )

        XCTAssertFalse(success)
        XCTAssertEqual(apiClient.getProfileCallCount, 1)
        XCTAssertEqual(apiClient.getMessageCallCount, 1)
        XCTAssertEqual(
            makeStateManager().getContinuationState(),
            BackgroundSyncContinuationState.partial(
                query: Self.partialQuery,
                pageToken: nil,
                maxResults: 50,
                startHistoryId: "history-expired",
                watermarkHistoryId: "history-watermark",
                accountEmail: "user@example.com"
            )
        )
        let storedHistoryId = await makeStateManager().getStoredHistoryId()
        XCTAssertEqual(storedHistoryId, "history-expired")
    }

    func testPartialSync_resumesTruncatedCheckpointWithoutRecapturingWatermark() async throws {
        try await makeStateManager().storeHistoryId(
            "history-expired",
            accountEmail: "user@example.com"
        )
        apiClient.profileResponse = makeProfile(
            email: "user@example.com",
            historyId: "history-watermark"
        )
        apiClient.listMessagesResponse = emptyMessagePage(nextPageToken: "page-2")
        apiClient.paginatedListMessagesResponses = [
            "page-2": emptyMessagePage(nextPageToken: "page-3"),
            "page-3": emptyMessagePage(nextPageToken: "page-4"),
            "page-4": emptyMessagePage(nextPageToken: nil)
        ]

        let manager = makeManager()
        let firstRunSucceeded = await manager.performPartialSync(
            query: Self.partialQuery,
            startHistoryId: "history-expired",
            isProcessingTask: false,
            accountEmail: "user@example.com"
        )

        XCTAssertFalse(firstRunSucceeded)
        XCTAssertEqual(apiClient.getProfileCallCount, 1)
        XCTAssertEqual(apiClient.listMessagesCallCount, 3)
        XCTAssertEqual(taskScheduler.retryBackoffs, [BackgroundSyncManager.catchUpRetryDelay])

        guard let checkpoint = makeStateManager().getContinuationState(),
              let checkpointQuery = checkpoint.query,
              let checkpointMaxResults = checkpoint.maxResults,
              let checkpointWatermark = checkpoint.watermarkHistoryId else {
            XCTFail("Expected a complete partial-sync checkpoint")
            return
        }
        XCTAssertEqual(checkpoint.pageToken, "page-4")
        XCTAssertEqual(checkpoint.startHistoryId, "history-expired")
        XCTAssertEqual(checkpointWatermark, "history-watermark")

        apiClient.profileResponse = makeProfile(
            email: "user@example.com",
            historyId: "history-must-not-be-used"
        )
        let resumedRunSucceeded = await manager.performPartialSync(
            query: checkpointQuery,
            initialPageToken: checkpoint.pageToken,
            maxResults: checkpointMaxResults,
            startHistoryId: checkpoint.startHistoryId,
            watermarkHistoryId: checkpointWatermark,
            isProcessingTask: false,
            accountEmail: checkpoint.accountEmail
        )

        XCTAssertTrue(resumedRunSucceeded)
        XCTAssertEqual(apiClient.getProfileCallCount, 1)
        XCTAssertEqual(apiClient.listMessagesCallCount, 4)
        XCTAssertEqual(apiClient.listMessagesLastPageToken, "page-4")
        XCTAssertEqual(
            apiClient.endpointCallOrder,
            ["getProfile", "listMessages", "listMessages", "listMessages", "listMessages"]
        )
        let storedHistoryId = await makeStateManager().getStoredHistoryId()
        XCTAssertEqual(storedHistoryId, "history-watermark")
        XCTAssertNil(makeStateManager().getContinuationState())
    }

    func testPartialSync_profileFailureAbortsBeforeListingOrCheckpointing() async throws {
        apiClient.getProfileError = APIError.timeout
        apiClient.listMessagesResponse = emptyMessagePage(nextPageToken: nil)

        let success = await makeManager().performPartialSync(
            query: Self.partialQuery,
            startHistoryId: nil,
            isProcessingTask: false,
            accountEmail: "user@example.com"
        )

        XCTAssertFalse(success)
        XCTAssertEqual(apiClient.endpointCallOrder, ["getProfile"])
        XCTAssertEqual(apiClient.listMessagesCallCount, 0)
        XCTAssertNil(makeStateManager().getContinuationState())
        let accounts = try await fetchAccountSnapshots()
        XCTAssertTrue(accounts.isEmpty)
    }

    private func makeManager(
        legacyDeltaSyncEnabled: Bool = true,
        authoritativeSyncExecutor: (any BackgroundMailboxSyncExecuting)? = nil,
        authoritativeSyncReadiness: @escaping @Sendable () async -> Bool = { true },
        authoritativeSyncIsAuthenticated: @escaping @MainActor @Sendable () -> Bool = { true }
    ) -> BackgroundSyncManager {
        let apiClient = apiClient!
        let syncCoordinator = BackgroundSyncNoopCoordinator()
        let executor = authoritativeSyncExecutor
        return BackgroundSyncManager(
            taskScheduler: taskScheduler,
            coreDataStack: coreDataStack,
            defaults: defaults,
            syncRunCoordinator: SyncRunCoordinator(),
            legacyDeltaSyncEnabled: legacyDeltaSyncEnabled,
            apiClientProvider: { apiClient },
            authoritativeSyncExecutorProvider: {
                executor ?? SyncEngine.shared
            },
            authoritativeSyncReadiness: authoritativeSyncReadiness,
            authoritativeSyncIsAuthenticated: authoritativeSyncIsAuthenticated,
            syncCoordinatorProvider: { syncCoordinator }
        )
    }

    private func makeStateManager() -> BackgroundSyncStateManager {
        BackgroundSyncStateManager(
            coreDataStack: coreDataStack,
            defaults: defaults
        )
    }

    private func fetchAccountSnapshots() async throws -> [BackgroundAccountSnapshot] {
        let context = testStack.newBackgroundContext()
        return try await context.perform {
            let request: NSFetchRequest<Account> = Account.fetchRequest()
            return try context.fetch(request).map {
                BackgroundAccountSnapshot(email: $0.email, historyId: $0.historyId)
            }
        }
    }

    private func makeProfile(email: String, historyId: String) -> GmailProfile {
        GmailProfile(
            emailAddress: email,
            messagesTotal: 0,
            threadsTotal: 0,
            historyId: historyId
        )
    }

    private func emptyMessagePage(nextPageToken: String?) -> MessagesListResponse {
        MessagesListResponse(
            messages: [],
            nextPageToken: nextPageToken,
            resultSizeEstimate: 0
        )
    }
}

@MainActor
private final class BackgroundMailboxSyncExecutorSpy: BackgroundMailboxSyncExecuting {
    private let result: BackgroundMailboxSyncExecutionResult
    private(set) var callCount = 0
    private(set) var budgets: [BackgroundMailboxSyncBudget] = []

    init(result: BackgroundMailboxSyncExecutionResult) {
        self.result = result
    }

    func performIncrementalSyncForBackground(
        budget: BackgroundMailboxSyncBudget
    ) async -> BackgroundMailboxSyncExecutionResult {
        callCount += 1
        budgets.append(budget)
        return result
    }
}

/// Returns a different outcome per call so one manager (and therefore one
/// retry-state counter) can be driven across a failure/recovery sequence.
private final class SequencedBackgroundMailboxSyncExecutorSpy: BackgroundMailboxSyncExecuting {
    private let results: [BackgroundMailboxSyncExecutionResult]
    private(set) var callCount = 0

    init(results: [BackgroundMailboxSyncExecutionResult]) {
        self.results = results
    }

    func performIncrementalSyncForBackground(
        budget: BackgroundMailboxSyncBudget
    ) async -> BackgroundMailboxSyncExecutionResult {
        defer { callCount += 1 }
        guard callCount < results.count else {
            // Name an over-run rather than silently substituting an outcome the
            // test never scripted, which would quietly change what it asserts.
            XCTFail("Executor called \(callCount + 1) times but only \(results.count) outcomes were scripted")
            return .failed
        }
        return results[callCount]
    }
}

@MainActor
private final class CancellableBackgroundMailboxSyncExecutorSpy: BackgroundMailboxSyncExecuting {
    private var didStart = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private(set) var wasCancelled = false

    func waitUntilStarted() async {
        guard !didStart else { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func performIncrementalSyncForBackground(
        budget: BackgroundMailboxSyncBudget
    ) async -> BackgroundMailboxSyncExecutionResult {
        didStart = true
        let waiters = startWaiters
        startWaiters.removeAll(keepingCapacity: false)
        waiters.forEach { $0.resume() }

        do {
            try await Task.sleep(nanoseconds: 60_000_000_000)
            return .completed
        } catch is CancellationError {
            wasCancelled = true
            return .failed
        } catch {
            return .failed
        }
    }
}

private actor BackgroundSyncReadinessGate {
    private var didStart = false
    private var waitInvocationCount = 0
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var result: Bool?
    private var readinessWaiters: [CheckedContinuation<Bool, Never>] = []

    func waitUntilReleased() async -> Bool {
        waitInvocationCount += 1
        didStart = true
        let waiters = startWaiters
        startWaiters.removeAll(keepingCapacity: false)
        waiters.forEach { $0.resume() }

        if let result {
            return result
        }
        return await withCheckedContinuation { continuation in
            readinessWaiters.append(continuation)
        }
    }

    func waitUntilStarted() async {
        guard !didStart else { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func invocationCount() -> Int {
        waitInvocationCount
    }

    func release(succeeded: Bool) {
        guard result == nil else { return }
        result = succeeded
        let waiters = readinessWaiters
        readinessWaiters.removeAll(keepingCapacity: false)
        waiters.forEach { $0.resume(returning: succeeded) }
    }
}

private actor BackgroundAuthenticationRestoreScript {
    private var outcomes: [AuthRestoreOutcome]
    private var calls = 0

    init(outcomes: [AuthRestoreOutcome]) {
        self.outcomes = outcomes
    }

    func restore() -> AuthRestoreOutcome {
        calls += 1
        guard !outcomes.isEmpty else {
            return .terminalNoSession
        }
        return outcomes.removeFirst()
    }

    func invocationCount() -> Int {
        calls
    }
}

private actor BackgroundPersistencePreparationScript {
    private var outcomes: [Bool]
    private var calls = 0

    init(outcomes: [Bool]) {
        self.outcomes = outcomes
    }

    func prepare() -> Bool {
        calls += 1
        guard !outcomes.isEmpty else {
            return false
        }
        return outcomes.removeFirst()
    }

    func invocationCount() -> Int {
        calls
    }
}

private struct BackgroundAccountSnapshot {
    let email: String
    let historyId: String?
}

private final class BackgroundTaskSchedulerSpy: BackgroundTaskScheduling {
    var onAppRefresh: ((BGAppRefreshTask) -> Void)?
    var onProcessing: ((BGProcessingTask) -> Void)?

    private(set) var retryBackoffs: [TimeInterval] = []
    private(set) var registrationCount = 0
    private(set) var appRefreshScheduleCount = 0
    private(set) var processingScheduleCount = 0
    var processingTaskPending = false

    func registerBackgroundTasks() { registrationCount += 1 }
    func scheduleAppRefresh() { appRefreshScheduleCount += 1 }
    func scheduleProcessingTask() { processingScheduleCount += 1 }
    func isProcessingTaskPending() async -> Bool { processingTaskPending }

    func scheduleRetryAfterBackoff(_ backoff: TimeInterval) {
        retryBackoffs.append(backoff)
    }
}

private final class BackgroundSyncNoopCoordinator: @unchecked Sendable, BackgroundSyncMessageCoordinating {
    func prefetchLabelIdsForBackground(in context: NSManagedObjectContext) async -> Set<String> {
        []
    }

    func saveMessage(
        _ gmailMessage: GmailMessage,
        labelIds: Set<String>?,
        modificationTransaction: ModificationTracker.Transaction,
        in context: NSManagedObjectContext
    ) async throws -> MessagePersistDisposition {
        .persisted
    }

    func updateConversationRollups(
        conversationIDs: Set<NSManagedObjectID>,
        in context: NSManagedObjectContext
    ) async {}

    func updateConversationDisplayNames(
        conversationIDs: Set<NSManagedObjectID>,
        in context: NSManagedObjectContext
    ) async {}
}
