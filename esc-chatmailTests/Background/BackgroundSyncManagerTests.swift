import XCTest
import BackgroundTasks
import CoreData
import Security
@testable import esc_chatmail

final class BackgroundSyncManagerTests: XCTestCase {
    private static let partialQuery = "after:123 -label:spam -label:drafts -label:trash"

    private var testStack: TestCoreDataStack!
    private var coreDataStack: CoreDataStack!
    private var defaults: UserDefaults!
    private var defaultsSuiteName: String!
    private var apiClient: MockGmailAPIClient!
    private var taskScheduler: BackgroundTaskSchedulerSpy!
    private var sceneAssertions: SceneBackgroundAssertionSpy!

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
        sceneAssertions = SceneBackgroundAssertionSpy()
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: defaultsSuiteName)
        sceneAssertions = nil
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
        await MainActor.run { manager.armBackgroundTasksForSceneBackground() }
        await waitUntil { self.sceneAssertions.endCount == 1 }

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
    // `scheduleProcessingTaskIfNotPending()` is dropped from the `.needsFollowUp`
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

    // Revert-check: fails if the escalation branch's guarded helper
    // (`scheduleProcessingTaskIfNotPending()`) stops consulting
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

    // Revert-check: fails if the `taskScheduler.scheduleProcessingTask()` submit
    // is dropped from `BackgroundSyncManager.scheduleProcessingTaskIfNotPending()`.
    // Companion to the pending-request test above: proves the guard is a guard,
    // not a no-op, so the pair together pins both sides of the branch.
    func testScheduleProcessingTaskIfNotPending_submitsWhenNoRequestIsPending() async {
        let manager = makeManager(legacyDeltaSyncEnabled: false)

        await manager.scheduleProcessingTaskIfNotPending()

        XCTAssertEqual(taskScheduler.processingScheduleCount, 1)
    }

    // The pending lookup suspends, so sign-out can cancel requests while this
    // helper is waiting. Its post-await auth re-check must share one MainActor
    // slice with the submit or it can re-arm behind that cancellation sweep.
    func testScheduleProcessingTaskIfNotPending_signOutDuringPendingCheck_submitsNothing() async {
        let authenticated = AuthGateBox(value: true)
        taskScheduler.onPendingCheck = {
            await MainActor.run { authenticated.value = false }
        }
        let manager = makeManager(
            legacyDeltaSyncEnabled: false,
            authoritativeSyncIsAuthenticated: { authenticated.value }
        )

        await manager.scheduleProcessingTaskIfNotPending()

        XCTAssertEqual(taskScheduler.processingScheduleCount, 0)
    }

    // Revert-check: fails if `armBackgroundTasksForSceneBackground()` stops
    // consulting `taskScheduler.isAppRefreshTaskPending()` before re-arming the
    // refresh identifier. An unconditional re-submit REPLACES the pending
    // request — including a sooner-dated failure-backoff or catch-up retry that
    // shares the identifier — postponing it to the plain 15-minute cadence.
    // Skipping never postpones: every refresh submit path uses a delay of at
    // most 15 minutes, so a pending request always begins no later than a
    // fresh re-submit would.
    func testArmBackgroundTasksForSceneBackground_doesNotReplacePendingRefreshRequest() async {
        let manager = makeManager(legacyDeltaSyncEnabled: false)
        taskScheduler.appRefreshTaskPending = true

        await MainActor.run { manager.armBackgroundTasksForSceneBackground() }
        await waitUntil { self.sceneAssertions.endCount == 1 }

        XCTAssertEqual(
            taskScheduler.appRefreshScheduleCount,
            0,
            "A pending refresh request (possibly a sooner-dated retry) must not be replaced"
        )
        XCTAssertEqual(
            taskScheduler.processingScheduleCount,
            1,
            "Skipping the refresh re-arm must not skip the processing arm"
        )
    }

    // Revert-check: fails if `armBackgroundTasksForSceneBackground()` stops
    // consulting the processing identifier's pending state before its submit —
    // the unguarded scene-background submit is the exact regression this arm
    // exists to prevent, pinned at the entry point the scene handler uses.
    // (The submit is deliberately direct rather than routed through
    // `scheduleProcessingTaskIfNotPending()`: it must share one MainActor
    // slice with the sign-out gate re-check below.)
    func testArmBackgroundTasksForSceneBackground_doesNotReplacePendingProcessingRequest() async {
        let manager = makeManager(legacyDeltaSyncEnabled: false)
        taskScheduler.processingTaskPending = true

        await MainActor.run { manager.armBackgroundTasksForSceneBackground() }
        await waitUntil { self.sceneAssertions.endCount == 1 }

        XCTAssertEqual(taskScheduler.appRefreshScheduleCount, 1)
        XCTAssertEqual(
            taskScheduler.processingScheduleCount,
            0,
            "A pending processing request must not be replaced (and thereby postponed)"
        )
    }

    // Revert-check: fails if `armBackgroundTasksForSceneBackground()` stops
    // consulting `authoritativeSyncIsAuthenticated` — the auth gate that
    // previously lived at the scene call site. A signed-out backgrounding must
    // arm nothing and take no background-execution assertion. (The assertion
    // is taken synchronously when the gate passes, so a dropped gate shows up
    // in `beginCount` immediately, with no async wait.)
    func testArmBackgroundTasksForSceneBackground_whenUnauthenticated_armsNothing() async {
        let manager = makeManager(
            legacyDeltaSyncEnabled: false,
            authoritativeSyncIsAuthenticated: { false }
        )

        await MainActor.run { manager.armBackgroundTasksForSceneBackground() }

        XCTAssertEqual(sceneAssertions.beginCount, 0)
        XCTAssertEqual(taskScheduler.appRefreshScheduleCount, 0)
        XCTAssertEqual(taskScheduler.processingScheduleCount, 0)
    }

    // Revert-check: fails if `armBackgroundTasksForSceneBackground()` stops
    // re-checking `authoritativeSyncIsAuthenticated` in the same MainActor
    // slice as its submits. The entry gate alone is insufficient: sign-out
    // drops the gate and then sweeps pending requests
    // (`cancelPendingTaskRequests`) while the arm is suspended in its pending
    // fetches, and a submit behind that stale gate re-arms the very wakes the
    // sweep just disarmed — the signed-out device then wakes on the sync
    // cadence indefinitely, the exact failure #171's disarm exists to prevent.
    func testArmBackgroundTasksForSceneBackground_signOutDuringPendingChecks_armsNothing() async {
        let authenticated = AuthGateBox(value: true)
        taskScheduler.onPendingCheck = {
            await MainActor.run { authenticated.value = false }
        }
        let manager = makeManager(
            legacyDeltaSyncEnabled: false,
            authoritativeSyncIsAuthenticated: { authenticated.value }
        )

        await MainActor.run { manager.armBackgroundTasksForSceneBackground() }
        await waitUntil { self.sceneAssertions.endCount == 1 }

        XCTAssertEqual(
            sceneAssertions.beginCount,
            1,
            "The gate passed at entry, so the assertion was taken"
        )
        XCTAssertEqual(
            taskScheduler.appRefreshScheduleCount,
            0,
            "A sign-out during the pending checks must abandon the refresh submit"
        )
        XCTAssertEqual(
            taskScheduler.processingScheduleCount,
            0,
            "A sign-out during the pending checks must abandon the processing submit"
        )
    }

    // Revert-check: fails if `armBackgroundTasksForSceneBackground()` stops
    // taking the background-execution assertion synchronously before its async
    // pending checks, or stops releasing it when the arm completes. Without
    // the assertion iOS may suspend the process between the scene transition
    // and the deferred submits, silently losing the arm for that backgrounding
    // — the guarantee the old synchronous submit provided by construction.
    // The begin count is read inside the same MainActor slice that called the
    // method: the arm's MainActor Task cannot have started yet, so a begin
    // moved inside the Task reads 0 here deterministically instead of racing
    // the Task's completion.
    func testArmBackgroundTasksForSceneBackground_holdsAssertionUntilArmCompletes() async {
        let manager = makeManager(legacyDeltaSyncEnabled: false)

        let beginCountAtReturn = await MainActor.run { () -> Int in
            manager.armBackgroundTasksForSceneBackground()
            return sceneAssertions.beginCount
        }

        XCTAssertEqual(
            beginCountAtReturn,
            1,
            "The assertion must be taken synchronously, before the scene transition completes"
        )
        await waitUntil { self.sceneAssertions.endCount == 1 }
        XCTAssertEqual(taskScheduler.appRefreshScheduleCount, 1)
        XCTAssertEqual(taskScheduler.processingScheduleCount, 1)
    }

    // UIKit can expire the short scene-background assertion while the system's
    // pending-request callback is withheld. Expiration must cancel the arm and
    // end its assertion without waiting for that callback; a late callback is
    // ignored by the scheduler's one-shot bridge.
    func testArmBackgroundTasksForSceneBackground_expirationUnblocksHungPendingQuery() async {
        let callbackProbe = BackgroundPendingRequestsCallbackProbe()
        let scheduler = BackgroundTaskScheduler(
            pendingTaskRequestsProvider: { callbackProbe.install($0) }
        )
        let manager = makeManager(
            taskSchedulerOverride: scheduler,
            legacyDeltaSyncEnabled: false
        )

        await MainActor.run { manager.armBackgroundTasksForSceneBackground() }
        await waitUntil { callbackProbe.hasCallback }

        await MainActor.run { self.sceneAssertions.expire() }
        await waitUntil { self.sceneAssertions.endInvocationCount == 2 }

        XCTAssertEqual(sceneAssertions.beginCount, 1)
        XCTAssertEqual(sceneAssertions.endCount, 1)
        XCTAssertEqual(sceneAssertions.endInvocationCount, 2)
        callbackProbe.fire(requests: [])
        await Task.yield()
        XCTAssertEqual(sceneAssertions.endCount, 1)
        XCTAssertEqual(sceneAssertions.endInvocationCount, 2)
    }

    // UIKit may decline the short assertion by returning `.invalid`; in that
    // case it never delivers an expiration callback. The failed grant is
    // treated as immediate expiration so no pending lookup starts unprotected.
    func testArmBackgroundTasksForSceneBackground_deniedAssertionStartsNoPendingQuery() async {
        let pendingChecks = BackgroundPendingCheckCounter()
        sceneAssertions.shouldGrant = false
        taskScheduler.onPendingCheck = { pendingChecks.increment() }
        let manager = makeManager(legacyDeltaSyncEnabled: false)

        await MainActor.run { manager.armBackgroundTasksForSceneBackground() }
        await waitUntil { self.sceneAssertions.endInvocationCount == 1 }

        XCTAssertEqual(sceneAssertions.beginCount, 1)
        XCTAssertEqual(sceneAssertions.endCount, 0)
        XCTAssertEqual(pendingChecks.value, 0)
        XCTAssertEqual(taskScheduler.appRefreshScheduleCount, 0)
        XCTAssertEqual(taskScheduler.processingScheduleCount, 0)
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

    // A sign-out can land while cold-launch readiness is suspended. Its gate
    // drop and first sweep must not be followed by the readiness-failure retry.
    func testModelV3Executor_signOutDuringBootstrapFailureDoesNotRearmRetry() async {
        let readinessGate = BackgroundSyncReadinessGate()
        let authenticated = AuthGateBox(value: true)
        taskScheduler.appRefreshTaskPending = true
        taskScheduler.processingTaskPending = true
        let manager = makeManager(
            legacyDeltaSyncEnabled: false,
            authoritativeSyncReadiness: {
                await readinessGate.waitUntilReleased()
            },
            authoritativeSyncIsAuthenticated: { authenticated.value },
            authoritativeSyncIsDurablySignedOut: { !authenticated.value }
        )
        let syncTask = Task {
            await manager.performAuthoritativeSync()
        }
        await readinessGate.waitUntilStarted()

        await MainActor.run {
            authenticated.value = false
            taskScheduler.cancelPendingTaskRequests()
        }
        await readinessGate.release(succeeded: false)
        let success = await syncTask.value

        XCTAssertFalse(success)
        XCTAssertTrue(taskScheduler.retryBackoffs.isEmpty)
        XCTAssertFalse(taskScheduler.appRefreshTaskPending)
        XCTAssertFalse(taskScheduler.processingTaskPending)
        XCTAssertEqual(
            taskScheduler.cancelPendingTaskRequestsCount,
            2,
            "The post-readiness verdict should repeat the sign-out sweep, not submit"
        )
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

    // Expiration may arrive while cold-launch readiness is suspended. Even
    // when readiness ultimately succeeds, the cancelled worker must still
    // sweep the cadence its handler re-armed for a durable sign-out.
    func testModelV3Executor_cancelledDuringReadinessDurableSignOutSweepsHandlerRearm() async {
        taskScheduler.appRefreshTaskPending = true
        taskScheduler.processingTaskPending = true
        let readinessGate = BackgroundSyncReadinessGate()
        let manager = makeManager(
            legacyDeltaSyncEnabled: false,
            authoritativeSyncReadiness: {
                await readinessGate.waitUntilReleased()
            },
            authoritativeSyncIsAuthenticated: { false },
            authoritativeSyncIsDurablySignedOut: { true }
        )
        let syncTask = Task {
            await manager.performAuthoritativeSync()
        }
        await readinessGate.waitUntilStarted()

        syncTask.cancel()
        await readinessGate.release(succeeded: true)
        let success = await syncTask.value

        XCTAssertFalse(success)
        XCTAssertEqual(taskScheduler.cancelPendingTaskRequestsCount, 1)
        XCTAssertFalse(taskScheduler.appRefreshTaskPending)
        XCTAssertFalse(taskScheduler.processingTaskPending)
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

    // Sign-out drops the auth gate and cancels requests contiguously on the
    // MainActor. Every executor-completion submit must pair a fresh gate check
    // with its submit in another MainActor slice: whichever slice wins, no
    // request can survive behind the sign-out sweep.
    func testModelV3Executor_signOutBeforeRetryingResult_doesNotRearmBackgroundWork() async {
        let retryingResults: [(String, BackgroundMailboxSyncExecutionResult)] = [
            ("failed", .failed),
            ("quiescence-blocked", .blocked(by: nil)),
            ("pending-actions-blocked", .blocked(by: .pendingActions)),
            ("needs-follow-up", .needsFollowUp)
        ]

        for (label, result) in retryingResults {
            let scheduler = BackgroundTaskSchedulerSpy()
            taskScheduler = scheduler
            let authenticated = AuthGateBox(value: true)
            let executor = await MainActor.run {
                BackgroundMailboxSyncExecutorSpy(result: result) {
                    authenticated.value = false
                    scheduler.cancelPendingTaskRequests()
                }
            }
            let manager = makeManager(
                legacyDeltaSyncEnabled: false,
                authoritativeSyncExecutor: executor,
                authoritativeSyncIsAuthenticated: { authenticated.value }
            )

            let success = await manager.performAuthoritativeSync(budget: .appRefresh)

            XCTAssertFalse(success, label)
            XCTAssertEqual(scheduler.cancelPendingTaskRequestsCount, 1, label)
            XCTAssertTrue(scheduler.retryBackoffs.isEmpty, label)
            XCTAssertEqual(scheduler.processingScheduleCount, 0, label)
        }
    }

    // Sign-out intent becomes durable before the published auth fields are
    // cleared. Post-executor scheduling must reject that intent even while the
    // old `canAccessMailbox` value is still true during account drains.
    func testModelV3Executor_durableSignOutIntentBeforeFailure_doesNotRearmRetry() async {
        let scheduler = taskScheduler!
        let authenticated = AuthGateBox(value: true)
        let durablySignedOut = AuthGateBox(value: false)
        let executor = await MainActor.run {
            BackgroundMailboxSyncExecutorSpy(result: .failed) {
                durablySignedOut.value = true
                scheduler.cancelPendingTaskRequests()
            }
        }
        let manager = makeManager(
            legacyDeltaSyncEnabled: false,
            authoritativeSyncExecutor: executor,
            authoritativeSyncIsAuthenticated: { authenticated.value },
            authoritativeSyncIsDurablySignedOut: { durablySignedOut.value }
        )

        let success = await manager.performAuthoritativeSync()

        XCTAssertFalse(success)
        XCTAssertEqual(scheduler.cancelPendingTaskRequestsCount, 1)
        XCTAssertTrue(scheduler.retryBackoffs.isEmpty)
    }

    // Expiration can arrive after the cooperative Task cancellation check.
    // The per-BGTask scheduling gate is expired from the auth-check hook, at
    // the final boundary before submission, so the retry and its counter update
    // must still be rejected atomically.
    func testModelV3Executor_cancellationAtFailureSubmitGateDoesNotConsumeRetry() async {
        let readinessGate = BackgroundSyncReadinessGate()
        let schedulingGate = BackgroundTaskSchedulingGate()
        let authenticated = AuthCancellationCheckBox(cancelOnCheck: 2)
        let executor = await MainActor.run {
            BackgroundMailboxSyncExecutorSpy(result: .failed)
        }
        let manager = makeManager(
            legacyDeltaSyncEnabled: false,
            authoritativeSyncExecutor: executor,
            authoritativeSyncReadiness: {
                await readinessGate.waitUntilReleased()
            },
            authoritativeSyncIsAuthenticated: { authenticated.check() }
        )
        let cancelledRun = Task {
            await manager.performAuthoritativeSync(schedulingGate: schedulingGate)
        }
        await MainActor.run {
            authenticated.cancel = {
                schedulingGate.expire()
                cancelledRun.cancel()
            }
        }
        await readinessGate.release(succeeded: true)

        let cancelledRunSucceeded = await cancelledRun.value
        XCTAssertFalse(cancelledRunSucceeded)
        XCTAssertTrue(taskScheduler.retryBackoffs.isEmpty)

        let nextRunSucceeded = await manager.performAuthoritativeSync()
        XCTAssertFalse(nextRunSucceeded)
        XCTAssertEqual(
            taskScheduler.retryBackoffs,
            [60],
            "The expired run must not spend the first retry-counter slot"
        )
    }

    func testModelV3Executor_cancellationAtFollowUpSubmitGateSchedulesNothing() async {
        let readinessGate = BackgroundSyncReadinessGate()
        let schedulingGate = BackgroundTaskSchedulingGate()
        let authenticated = AuthCancellationCheckBox(cancelOnCheck: 2)
        let executor = await MainActor.run {
            BackgroundMailboxSyncExecutorSpy(result: .needsFollowUp)
        }
        let manager = makeManager(
            legacyDeltaSyncEnabled: false,
            authoritativeSyncExecutor: executor,
            authoritativeSyncReadiness: {
                await readinessGate.waitUntilReleased()
            },
            authoritativeSyncIsAuthenticated: { authenticated.check() }
        )
        let cancelledRun = Task {
            await manager.performAuthoritativeSync(
                budget: .appRefresh,
                schedulingGate: schedulingGate
            )
        }
        await MainActor.run {
            authenticated.cancel = {
                schedulingGate.expire()
                cancelledRun.cancel()
            }
        }
        await readinessGate.release(succeeded: true)

        let cancelledRunSucceeded = await cancelledRun.value
        XCTAssertFalse(cancelledRunSucceeded)
        XCTAssertEqual(taskScheduler.processingScheduleCount, 0)
        XCTAssertTrue(taskScheduler.retryBackoffs.isEmpty)
    }

    // A BGTask handler re-arms before its Swift worker is installed. If system
    // expiration wins that installation race, the pre-cancelled worker must
    // still remove the just-submitted cadence for a durable sign-out.
    func testModelV3Executor_preCancelledDurableSignOutSweepsHandlerRearm() async {
        taskScheduler.appRefreshTaskPending = true
        taskScheduler.processingTaskPending = true
        let manager = makeManager(
            legacyDeltaSyncEnabled: false,
            authoritativeSyncIsAuthenticated: { false },
            authoritativeSyncIsDurablySignedOut: { true }
        )
        let workerStartGate = BackgroundSyncReadinessGate()
        let cancellationLatch = BackgroundTaskCancellationLatch()
        let worker = Task {
            _ = await workerStartGate.waitUntilReleased()
            return await manager.performAuthoritativeSync()
        }
        await workerStartGate.waitUntilStarted()

        cancellationLatch.expire()
        cancellationLatch.install { worker.cancel() }
        await workerStartGate.release(succeeded: true)
        let success = await worker.value

        XCTAssertFalse(success)
        XCTAssertEqual(taskScheduler.cancelPendingTaskRequestsCount, 1)
        XCTAssertFalse(taskScheduler.appRefreshTaskPending)
        XCTAssertFalse(taskScheduler.processingTaskPending)
    }

    // The system can expire a delivered BGTask synchronously while its handler
    // is still creating the Swift worker. Both handler budgets must apply that
    // remembered cancellation before work starts, run the signed-out sweep,
    // and only then report completion.
    func testTaskRunner_expirationBeforeWorkerCreationSweepsBeforeCompletion() async {
        let executor = await MainActor.run {
            BackgroundMailboxSyncExecutorSpy(result: .completed)
        }
        let manager = makeManager(
            legacyDeltaSyncEnabled: false,
            authoritativeSyncExecutor: executor,
            authoritativeSyncIsAuthenticated: { false },
            authoritativeSyncIsDurablySignedOut: { true }
        )

        for (index, budget) in [
            BackgroundMailboxSyncBudget.appRefresh,
            .processing
        ].enumerated() {
            taskScheduler.appRefreshTaskPending = true
            taskScheduler.processingTaskPending = true
            let completion = BackgroundTaskCompletionProbe()

            manager.runBackgroundTaskOperation(
                budget: budget,
                installExpirationHandler: { handler in handler() },
                onComplete: { completion.record($0) }
            )
            await waitUntil { completion.outcomes.count == 1 }

            XCTAssertEqual(completion.outcomes, [false], "Budget: \(budget)")
            XCTAssertEqual(
                taskScheduler.cancelPendingTaskRequestsCount,
                index + 1,
                "Completion must observe the durable sweep for budget: \(budget)"
            )
            XCTAssertFalse(taskScheduler.appRefreshTaskPending)
            XCTAssertFalse(taskScheduler.processingTaskPending)
        }

        let callCount = await MainActor.run { executor.callCount }
        XCTAssertEqual(callCount, 0)
    }

    // Expiration requests cancellation while readiness is suspended, but must
    // retain the BG execution grant until the cancelled worker resumes, runs
    // its durable sweep, and returns. This pins the ordering shared by both
    // real BGTask handlers without constructing Apple's private task classes.
    func testTaskRunner_expirationDefersCompletionUntilCancelledWorkerUnwinds() async {
        for budget in [BackgroundMailboxSyncBudget.appRefresh, .processing] {
            taskScheduler.appRefreshTaskPending = true
            taskScheduler.processingTaskPending = true
            let readinessGate = BackgroundSyncReadinessGate()
            let expiration = BackgroundTaskExpirationHandlerProbe()
            let completion = BackgroundTaskCompletionProbe()
            let manager = makeManager(
                legacyDeltaSyncEnabled: false,
                authoritativeSyncReadiness: {
                    await readinessGate.waitUntilReleased()
                },
                authoritativeSyncIsAuthenticated: { false },
                authoritativeSyncIsDurablySignedOut: { true }
            )

            manager.runBackgroundTaskOperation(
                budget: budget,
                installExpirationHandler: { expiration.install($0) },
                onComplete: { completion.record($0) }
            )
            await readinessGate.waitUntilStarted()

            expiration.fire()
            XCTAssertTrue(completion.outcomes.isEmpty)
            XCTAssertTrue(taskScheduler.appRefreshTaskPending)
            XCTAssertTrue(taskScheduler.processingTaskPending)

            await readinessGate.release(succeeded: true)
            await waitUntil { completion.outcomes.count == 1 }

            XCTAssertEqual(completion.outcomes, [false], "Budget: \(budget)")
            XCTAssertFalse(taskScheduler.appRefreshTaskPending)
            XCTAssertFalse(taskScheduler.processingTaskPending)
        }
    }

    // `BGTaskScheduler.getPendingTaskRequests` is callback-based and the system
    // does not promise when that callback arrives. Expiration must still unwind
    // a refresh worker that is waiting to decide whether processing escalation
    // is already pending; a late system callback must be harmless.
    func testTaskRunner_expirationUnblocksHungPendingRequestQuery() async {
        let callbackProbe = BackgroundPendingRequestsCallbackProbe()
        let scheduler = BackgroundTaskScheduler(
            pendingTaskRequestsProvider: { callbackProbe.install($0) }
        )
        let executor = await MainActor.run {
            BackgroundMailboxSyncExecutorSpy(result: .needsFollowUp)
        }
        let expiration = BackgroundTaskExpirationHandlerProbe()
        let completion = BackgroundTaskCompletionProbe()
        let manager = makeManager(
            taskSchedulerOverride: scheduler,
            legacyDeltaSyncEnabled: false,
            authoritativeSyncExecutor: executor
        )

        manager.runBackgroundTaskOperation(
            budget: .appRefresh,
            installExpirationHandler: { expiration.install($0) },
            onComplete: { completion.record($0) }
        )
        await waitUntil { callbackProbe.hasCallback }

        expiration.fire()
        await waitUntil(timeout: 1.0) { completion.outcomes.count == 1 }

        XCTAssertEqual(completion.outcomes, [false])
        callbackProbe.fire(requests: [])
        await waitUntil { completion.outcomes.count == 1 }
        XCTAssertEqual(completion.outcomes, [false])
    }

    // Revert-check: fails if the unauthenticated branch of
    // `performAuthoritativeSync()` drops its self-heal call to
    // `taskScheduler.cancelPendingTaskRequests()`. Devices that signed out
    // before sign-out learned to cancel its pending BGTask requests are stuck
    // in a perpetual re-arm chain — the handlers re-arm at entry, then the
    // unauthenticated guard turns the run into a no-op — so this call is the
    // only thing that ever removes their requests.
    func testModelV3Executor_unauthenticatedDurablySignedOut_cancelsPendingTaskRequests() async {
        let executor = await MainActor.run {
            BackgroundMailboxSyncExecutorSpy(result: .completed)
        }
        let manager = makeManager(
            legacyDeltaSyncEnabled: false,
            authoritativeSyncExecutor: executor,
            authoritativeSyncIsAuthenticated: { false },
            authoritativeSyncIsDurablySignedOut: { true }
        )
        taskScheduler.appRefreshTaskPending = true
        taskScheduler.processingTaskPending = true

        let success = await manager.performAuthoritativeSync()

        XCTAssertTrue(success, "The stale request itself is still a successful no-op")
        XCTAssertEqual(taskScheduler.cancelPendingTaskRequestsCount, 1)
        XCTAssertFalse(taskScheduler.appRefreshTaskPending)
        XCTAssertFalse(taskScheduler.processingTaskPending)
        XCTAssertEqual(
            taskScheduler.retryBackoffs,
            [],
            "A durably signed-out device must not queue any follow-up work"
        )
        let callCount = await MainActor.run { executor.callCount }
        XCTAssertEqual(callCount, 0)
    }

    // Revert-check: fails if the self-heal stops consulting
    // `authoritativeSyncIsDurablySignedOut` and cancels on the unauthenticated
    // guard alone. Bootstrap "success" also covers a cold-launch restore that
    // failed transiently (e.g. network down) with the keychain-persisted
    // session intact; cancelling then would disarm a signed-in user's
    // background cadence until their next foreground backgrounding re-arms it.
    func testModelV3Executor_unauthenticatedTransientRestoreFailure_keepsPendingTaskRequests() async {
        let executor = await MainActor.run {
            BackgroundMailboxSyncExecutorSpy(result: .completed)
        }
        let manager = makeManager(
            legacyDeltaSyncEnabled: false,
            authoritativeSyncExecutor: executor,
            authoritativeSyncIsAuthenticated: { false },
            authoritativeSyncIsDurablySignedOut: { false }
        )

        let success = await manager.performAuthoritativeSync()

        XCTAssertTrue(success)
        XCTAssertEqual(
            taskScheduler.cancelPendingTaskRequestsCount,
            0,
            "An indeterminate or possibly-live session must keep its pending requests"
        )
        let callCount = await MainActor.run { executor.callCount }
        XCTAssertEqual(callCount, 0)
    }

    // A registered removal is definitive before sign-out clears the published
    // auth state. That positive verdict must close execution immediately.
    func testModelV3Executor_authenticatedRemovalIntent_cancelsPendingTaskRequests() async {
        let executor = await MainActor.run {
            BackgroundMailboxSyncExecutorSpy(result: .completed)
        }
        let manager = makeManager(
            legacyDeltaSyncEnabled: false,
            authoritativeSyncExecutor: executor,
            authoritativeSyncIsAuthenticated: { true },
            authoritativeSyncIsDurablySignedOut: { true }
        )

        let success = await manager.performAuthoritativeSync()

        XCTAssertTrue(success)
        XCTAssertEqual(taskScheduler.cancelPendingTaskRequestsCount, 1)
        let callCount = await MainActor.run { executor.callCount }
        XCTAssertEqual(callCount, 0)
    }

    // Revert-check: fails if `AuthSession.isDurablySignedOut()` stops treating
    // a definitive keychain `.itemNotFound` as the signed-out verdict — a
    // completed sign-out deletes the persisted email inside its durable
    // credential transaction, so absence is exactly the pre-fix population the
    // background self-heal exists to disarm.
    func testDurableSignOutVerdict_persistedEmailAbsent_reportsSignedOut() async {
        let keychain = MockKeychainService()

        let verdict = await MainActor.run {
            makeDurableSignOutProbeSession(keychain: keychain).isDurablySignedOut()
        }

        XCTAssertTrue(verdict)
    }

    // Older builds could leave a valid Google SDK session without ever
    // persisting this app's email key. That SDK marker makes a missing email
    // indeterminate during a transient cold-launch restore failure.
    func testDurableSignOutVerdict_legacySDKSessionWithoutPersistedEmail_reportsPossiblyLive() async {
        let keychain = MockKeychainService()

        let verdict = await MainActor.run {
            makeDurableSignOutProbeSession(
                keychain: keychain,
                hasPreviousGoogleSignIn: { true }
            ).isDurablySignedOut()
        }

        XCTAssertFalse(verdict)
    }

    // GoogleSignIn's Boolean probe suppresses keychain and decode errors. The
    // raw item still being present must therefore override a false Boolean.
    func testDurableSignOutVerdict_rawLegacySDKItemPresent_reportsPossiblyLive() async {
        let keychain = MockKeychainService()

        let verdict = await MainActor.run {
            makeDurableSignOutProbeSession(
                keychain: keychain,
                hasPreviousGoogleSignIn: { false },
                googleSignInKeychainPresence: { .present }
            ).isDurablySignedOut()
        }

        XCTAssertFalse(verdict)
    }

    func testDurableSignOutVerdict_sdkKeychainReadIndeterminate_reportsPossiblyLive() async {
        let keychain = MockKeychainService()

        let verdict = await MainActor.run {
            makeDurableSignOutProbeSession(
                keychain: keychain,
                googleSignInKeychainPresence: { .indeterminate }
            ).isDurablySignedOut()
        }

        XCTAssertFalse(verdict)
    }

    func testDurableSignOutVerdict_liveAuthenticatedStateOverridesMissingCredentials() async {
        let keychain = MockKeychainService()

        let verdict = await MainActor.run { () -> Bool in
            let session = makeDurableSignOutProbeSession(keychain: keychain)
            session.isAuthenticated = true
            return session.isDurablySignedOut()
        }

        XCTAssertFalse(verdict)
    }

    func testDurableSignOutVerdict_cleanupIntentOverridesSurvivingEmail() async throws {
        let keychain = MockKeychainService()
        keychain.preloadStrings([
            KeychainService.Key.googleUserEmail.rawValue: "old@example.com"
        ])
        try keychain.save(
            Data([1]),
            for: KeychainService.Key.localStoreResetRequired.rawValue,
            withAccess: .afterFirstUnlockThisDeviceOnly
        )

        let verdict = await MainActor.run {
            makeDurableSignOutProbeSession(keychain: keychain).isDurablySignedOut()
        }

        XCTAssertTrue(verdict)
    }

    func testDurableSignOutVerdict_durableMarkerOverridesSurvivingSDKAndEmail() async throws {
        let keychain = MockKeychainService()
        keychain.preloadStrings([
            KeychainService.Key.googleUserEmail.rawValue: "old@example.com"
        ])
        try keychain.save(
            Data([1]),
            for: KeychainService.Key.durableSignedOut.rawValue,
            withAccess: .afterFirstUnlockThisDeviceOnly
        )

        let verdict = await MainActor.run {
            makeDurableSignOutProbeSession(
                keychain: keychain,
                hasPreviousGoogleSignIn: { true },
                googleSignInKeychainPresence: { .present }
            ).isDurablySignedOut()
        }

        XCTAssertTrue(
            verdict,
            "App-owned sign-out intent must outlive a failed SDK keychain delete"
        )
    }

    // A persisted app email plus an unreadable SDK source remains possibly
    // live. The app-owned key cannot authenticate by itself, but neither may a
    // transient SDK keychain failure be collapsed into definitive absence.
    func testDurableSignOutVerdict_persistedEmailWithIndeterminateSDK_reportsPossiblyLive() async {
        let keychain = MockKeychainService()
        keychain.preloadStrings([
            KeychainService.Key.googleUserEmail.rawValue: "user@example.com"
        ])

        let verdict = await MainActor.run {
            makeDurableSignOutProbeSession(
                keychain: keychain,
                googleSignInKeychainPresence: { .indeterminate }
            ).isDurablySignedOut()
        }

        XCTAssertFalse(verdict)
    }

    // The SDK session is the restorable authority. A readable orphaned app
    // email must not preserve the perpetual handler re-arm when both Google
    // probes definitively report no session.
    func testDurableSignOutVerdict_persistedEmailWithDefinitiveSDKAbsence_reportsSignedOut() async {
        let keychain = MockKeychainService()
        keychain.preloadStrings([
            KeychainService.Key.googleUserEmail.rawValue: "orphaned@example.com"
        ])

        let verdict = await MainActor.run {
            makeDurableSignOutProbeSession(
                keychain: keychain,
                hasPreviousGoogleSignIn: { false },
                googleSignInKeychainPresence: { .absent }
            ).isDurablySignedOut()
        }

        XCTAssertTrue(verdict)
    }

    // Revert-check: fails if `isDurablySignedOut()` collapses an indeterminate
    // keychain failure into "signed out" — e.g. if reimplemented on top of
    // `currentOrPersistedUserEmail() == nil`, which returns nil for *any*
    // keychain error. A read rejected before first unlock says nothing about
    // the session, and cancelling on it would disarm a signed-in user's
    // background cadence, so an unreadable keychain must fail safe.
    func testDurableSignOutVerdict_indeterminateKeychainRead_failsSafeAsPossiblyLive() async {
        let keychain = MockKeychainService()
        keychain.errorToThrow = KeychainError.unhandledError(status: errSecInteractionNotAllowed)

        let verdict = await MainActor.run {
            makeDurableSignOutProbeSession(keychain: keychain).isDurablySignedOut()
        }

        XCTAssertFalse(verdict)
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

        await MainActor.run { manager.armBackgroundTasksForSceneBackground() }
        await waitUntil { self.sceneAssertions.endCount == 1 }

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
        taskSchedulerOverride: (any BackgroundTaskScheduling)? = nil,
        legacyDeltaSyncEnabled: Bool = true,
        authoritativeSyncExecutor: (any BackgroundMailboxSyncExecuting)? = nil,
        authoritativeSyncReadiness: @escaping @Sendable () async -> Bool = { true },
        authoritativeSyncIsAuthenticated: @escaping @MainActor @Sendable () -> Bool = { true },
        authoritativeSyncIsDurablySignedOut: @escaping @MainActor @Sendable () -> Bool = { false }
    ) -> BackgroundSyncManager {
        let apiClient = apiClient!
        let syncCoordinator = BackgroundSyncNoopCoordinator()
        let executor = authoritativeSyncExecutor
        let assertions = sceneAssertions!
        return BackgroundSyncManager(
            taskScheduler: taskSchedulerOverride ?? taskScheduler,
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
            authoritativeSyncIsDurablySignedOut: authoritativeSyncIsDurablySignedOut,
            syncCoordinatorProvider: { syncCoordinator },
            beginSceneBackgroundAssertion: { onExpiration in
                assertions.begin(onExpiration: onExpiration)
                return { assertions.end() }
            }
        )
    }

    private func waitUntil(
        timeout: TimeInterval = 5.0,
        pollIntervalNanoseconds: UInt64 = 10_000_000,
        file: StaticString = #filePath,
        line: UInt = #line,
        condition: @escaping () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() {
                return
            }
            try? await Task.sleep(nanoseconds: pollIntervalNanoseconds)
        }
        XCTFail("Timed out waiting for condition", file: file, line: line)
    }

    private func makeStateManager() -> BackgroundSyncStateManager {
        BackgroundSyncStateManager(
            coreDataStack: coreDataStack,
            defaults: defaults
        )
    }

    /// A fully isolated `AuthSession` for probing `isDurablySignedOut()`:
    /// every singleton-typed collaborator is a fresh instance, so the verdict
    /// comes only from the injected keychain and SDK-session signal.
    @MainActor
    private func makeDurableSignOutProbeSession(
        keychain: MockKeychainService,
        hasPreviousGoogleSignIn: @escaping @MainActor @Sendable () -> Bool = { false },
        googleSignInKeychainPresence: @escaping @Sendable () -> GoogleSignInKeychainPresence = { .absent }
    ) -> AuthSession {
        AuthSession(
            tokenManagerProvider: { MockTokenManager() },
            keychainService: keychain,
            hasPreviousGoogleSignIn: hasPreviousGoogleSignIn,
            googleSignInKeychainPresence: googleSignInKeychainPresence,
            userDefaults: UserDefaults(
                suiteName: "BackgroundSyncManagerTests-auth-\(UUID().uuidString)"
            )!,
            syncRunCoordinator: SyncRunCoordinator(),
            outboundTaskRegistry: OutboundTaskRegistry()
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
    private let onPerform: @MainActor () -> Void
    private(set) var callCount = 0
    private(set) var budgets: [BackgroundMailboxSyncBudget] = []

    init(
        result: BackgroundMailboxSyncExecutionResult,
        onPerform: @escaping @MainActor () -> Void = {}
    ) {
        self.result = result
        self.onPerform = onPerform
    }

    func performIncrementalSyncForBackground(
        budget: BackgroundMailboxSyncBudget
    ) async -> BackgroundMailboxSyncExecutionResult {
        callCount += 1
        budgets.append(budget)
        onPerform()
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
    private(set) var cancelPendingTaskRequestsCount = 0
    var processingTaskPending = false
    var appRefreshTaskPending = false

    func registerBackgroundTasks() { registrationCount += 1 }

    // Submits mirror the real scheduler's read-your-write coupling: a
    // synchronous `BGTaskScheduler.submit` is immediately visible to a
    // subsequent `getPendingTaskRequests`, so the guarded arms are idempotent
    // across sequential calls in production — the spy must not model the
    // pending state as absent or a double-submit regression would look normal
    // here while production submits once.
    func scheduleAppRefresh() {
        appRefreshScheduleCount += 1
        appRefreshTaskPending = true
    }

    func scheduleProcessingTask() {
        processingScheduleCount += 1
        processingTaskPending = true
    }

    /// Runs inside the arm's suspension points, letting tests mutate state
    /// (e.g. drop the auth gate) exactly where a concurrent sign-out could.
    var onPendingCheck: (@Sendable () async -> Void)?

    func isProcessingTaskPending() async -> Bool {
        await onPendingCheck?()
        return processingTaskPending
    }

    func isAppRefreshTaskPending() async -> Bool {
        await onPendingCheck?()
        return appRefreshTaskPending
    }

    func cancelPendingTaskRequests() {
        cancelPendingTaskRequestsCount += 1
        appRefreshTaskPending = false
        processingTaskPending = false
    }

    func scheduleRetryAfterBackoff(_ backoff: TimeInterval) {
        retryBackoffs.append(backoff)
        // Backoff retries submit the refresh identifier.
        appRefreshTaskPending = true
    }
}

private final class BackgroundTaskCompletionProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var storedOutcomes: [Bool] = []

    var outcomes: [Bool] {
        lock.lock()
        defer { lock.unlock() }
        return storedOutcomes
    }

    func record(_ outcome: Bool) {
        lock.lock()
        storedOutcomes.append(outcome)
        lock.unlock()
    }
}

private final class BackgroundTaskExpirationHandlerProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var handler: (() -> Void)?

    func install(_ handler: @escaping () -> Void) {
        lock.lock()
        self.handler = handler
        lock.unlock()
    }

    func fire() {
        lock.lock()
        let handler = self.handler
        lock.unlock()
        handler?()
    }
}

private final class BackgroundPendingRequestsCallbackProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var callback: (([BGTaskRequest]) -> Void)?

    var hasCallback: Bool {
        lock.lock()
        defer { lock.unlock() }
        return callback != nil
    }

    func install(_ callback: @escaping ([BGTaskRequest]) -> Void) {
        lock.lock()
        self.callback = callback
        lock.unlock()
    }

    func fire(requests: [BGTaskRequest]) {
        lock.lock()
        let callback = self.callback
        self.callback = nil
        lock.unlock()
        callback?(requests)
    }
}

/// MainActor-isolated mutable authentication gate: tests flip it at a precise
/// suspension point inside the arm (via the scheduler spy's `onPendingCheck`
/// hook) to model a sign-out landing while the arm is suspended. All access —
/// the manager's `@MainActor` gate closure and the hook's flip — goes through
/// the MainActor, so reads and writes cannot race.
@MainActor
private final class AuthGateBox {
    var value: Bool
    /// Nonisolated so nonisolated async test bodies can construct the box;
    /// a nonisolated init may initialize isolated stored properties directly.
    nonisolated init(value: Bool) { self.value = value }
}

@MainActor
private final class AuthCancellationCheckBox {
    private let cancelOnCheck: Int
    private var checkCount = 0
    var cancel: @MainActor () -> Void = {}

    nonisolated init(cancelOnCheck: Int) {
        self.cancelOnCheck = cancelOnCheck
    }

    func check() -> Bool {
        checkCount += 1
        if checkCount == cancelOnCheck {
            cancel()
        }
        return true
    }
}

/// Records the background-execution assertion pairing around
/// `armBackgroundTasksForSceneBackground()`. Counters are mutated on the
/// MainActor (begin in the arm method, end in its MainActor-inherited Task)
/// and only polled read-only by tests.
private final class SceneBackgroundAssertionSpy {
    private(set) var beginCount = 0
    private(set) var endCount = 0
    private(set) var endInvocationCount = 0
    var shouldGrant = true
    private var isActive = false
    private var onExpiration: (@MainActor @Sendable () -> Void)?

    @MainActor
    func begin(onExpiration: @escaping @MainActor @Sendable () -> Void) {
        guard !isActive else { return }
        beginCount += 1
        guard shouldGrant else {
            onExpiration()
            return
        }
        isActive = true
        self.onExpiration = onExpiration
    }

    @MainActor
    func end() {
        endInvocationCount += 1
        guard isActive else { return }
        isActive = false
        onExpiration = nil
        endCount += 1
    }

    @MainActor
    func expire() {
        guard isActive else { return }
        onExpiration?()
        end()
    }
}

private final class BackgroundPendingCheckCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func increment() {
        lock.lock()
        count += 1
        lock.unlock()
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
