import XCTest
@testable import esc_chatmail

@MainActor
final class ForegroundSyncCoordinatorTests: XCTestCase {
    // Revert-check: fails if either `guard authSession.canAccessMailbox` reverts
    // to `isAuthenticated` — the one in start(reason:triggerImmediateSync:)
    // (start would return true) or the one in
    // requestSyncIfNeeded(reason:force:remainingImmediateFollowUps:), which the
    // three trigger calls below all funnel through. A session holding a revoked
    // token would keep issuing sync requests that can only fail.
    func testReauthenticationRequirementBlocksEveryForegroundSyncEntryPoint() async {
        let syncEngine = MockForegroundSyncEngine()
        let authSession = MockForegroundSyncAuthSession(isAuthenticated: true)
        authSession.requiresReauthentication = true
        let coordinator = ForegroundSyncCoordinator(
            syncEngine: syncEngine,
            authSession: authSession,
            periodicInterval: 3_600,
            minimumSyncGap: 0
        )
        defer { coordinator.stop(reason: "testCleanup") }

        XCTAssertFalse(
            coordinator.start(reason: "reauthenticationRequired", triggerImmediateSync: true)
        )
        coordinator.triggerSync(reason: "racingImmediateRequest", force: true)
        await coordinator.performUserInitiatedSync(reason: "pullToRefresh")
        try? await coordinator.performIncrementalSync()
        await Task.yield()

        XCTAssertEqual(syncEngine.triggerIncrementalSyncIfPossibleCalls, 0)
    }

    // Revert-check (combined): fails only when BOTH canAccessMailbox guards —
    // scheduleImmediateFollowUp's (reached FIRST on the completion path) and
    // requestSyncIfNeeded's — revert to `isAuthenticated`; each alone is
    // masked by the other, because whichever survives still kills the
    // needsFollowUp continuation before dead credentials re-trigger a sync.
    // HONEST SCOPE: no single-hunk revert fails this test; it pins the pair.
    func testReauthenticationRequirementSuppressesActiveSessionContinuation() async {
        let syncEngine = MockForegroundSyncEngine()
        let authSession = MockForegroundSyncAuthSession(isAuthenticated: true)
        let coordinator = ForegroundSyncCoordinator(
            syncEngine: syncEngine,
            authSession: authSession,
            periodicInterval: 3_600,
            minimumSyncGap: 0
        )
        defer { coordinator.stop(reason: "testCleanup") }

        let initialSyncStarted = expectation(description: "initial sync")
        syncEngine.onTriggerIncrementalSyncIfPossible = {
            initialSyncStarted.fulfill()
            return .started
        }
        XCTAssertTrue(coordinator.start(reason: "active", triggerImmediateSync: true))
        await fulfillment(of: [initialSyncStarted], timeout: 1.0)

        authSession.requiresReauthentication = true
        syncEngine.completeRequest(at: 0, needsFollowUp: true)
        try? await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertEqual(syncEngine.triggerIncrementalSyncIfPossibleCalls, 1)
    }

    func testStart_triggerImmediateSync_runsOnFreshStart() async {
        let syncEngine = MockForegroundSyncEngine()
        let authSession = MockForegroundSyncAuthSession(isAuthenticated: true)
        let coordinator = ForegroundSyncCoordinator(
            syncEngine: syncEngine,
            authSession: authSession,
            periodicInterval: 3_600,
            minimumSyncGap: 90
        )

        defer { coordinator.stop(reason: "testCleanup") }

        let syncExpectation = expectation(description: "initial sync")
        syncEngine.onTriggerIncrementalSyncIfPossible = {
            syncExpectation.fulfill()
            return .started
        }

        coordinator.start(reason: "appInitialized", triggerImmediateSync: true)

        await fulfillment(of: [syncExpectation], timeout: 1.0)
        XCTAssertEqual(syncEngine.triggerIncrementalSyncIfPossibleCalls, 1)
    }

    func testStart_triggerImmediateSyncDefersUntilAccountTransitionBoundaryReopens() async {
        let syncEngine = MockForegroundSyncEngine()
        let authSession = MockForegroundSyncAuthSession(isAuthenticated: true)
        let coordinator = ForegroundSyncCoordinator(
            syncEngine: syncEngine,
            authSession: authSession,
            periodicInterval: 3_600,
            minimumSyncGap: 90
        )
        defer { coordinator.stop(reason: "testCleanup") }

        let boundaryWaitStarted = expectation(description: "waiting for account transition")
        let deferredSyncStarted = expectation(description: "deferred sync started")
        let boundary = AsyncGate()
        syncEngine.requestResults = [.alreadyInProgress, .started]
        syncEngine.onWaitForCurrentSyncToComplete = {
            boundaryWaitStarted.fulfill()
            await boundary.wait()
        }
        syncEngine.onTriggerIncrementalSyncIfPossible = {
            let result = syncEngine.requestResults.removeFirst()
            if result == .started {
                deferredSyncStarted.fulfill()
            }
            return result
        }

        coordinator.start(reason: "authBecameAuthenticated", triggerImmediateSync: true)

        await fulfillment(of: [boundaryWaitStarted], timeout: 1.0)
        XCTAssertEqual(syncEngine.triggerIncrementalSyncIfPossibleCalls, 1)

        await boundary.open()
        await fulfillment(of: [deferredSyncStarted], timeout: 1.0)
        XCTAssertEqual(syncEngine.triggerIncrementalSyncIfPossibleCalls, 2)
    }

    func testCompletedHistorySliceNeedingFollowUpStartsImmediateContinuation() async {
        let syncEngine = MockForegroundSyncEngine()
        let authSession = MockForegroundSyncAuthSession(isAuthenticated: true)
        let coordinator = ForegroundSyncCoordinator(
            syncEngine: syncEngine,
            authSession: authSession,
            periodicInterval: 3_600,
            minimumSyncGap: 3_600,
            maxImmediateFollowUpRuns: 2
        )
        defer { coordinator.stop(reason: "testCleanup") }

        let firstSliceStarted = expectation(description: "first history slice")
        let continuationStarted = expectation(description: "history continuation")
        syncEngine.onTriggerIncrementalSyncIfPossible = {
            if syncEngine.triggerIncrementalSyncIfPossibleCalls == 1 {
                firstSliceStarted.fulfill()
            } else if syncEngine.triggerIncrementalSyncIfPossibleCalls == 2 {
                continuationStarted.fulfill()
            }
            return .started
        }

        coordinator.start(reason: "appInitialized", triggerImmediateSync: true)
        await fulfillment(of: [firstSliceStarted], timeout: 1.0)
        XCTAssertEqual(syncEngine.triggerIncrementalSyncIfPossibleCalls, 1)

        syncEngine.completeRequest(at: 0, needsFollowUp: true)

        await fulfillment(of: [continuationStarted], timeout: 1.0)
        XCTAssertEqual(
            syncEngine.triggerIncrementalSyncIfPossibleCalls,
            2,
            "The durable next-page checkpoint should be consumed without waiting for the periodic timer"
        )

        syncEngine.completeRequest(at: 1, needsFollowUp: false)
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(syncEngine.triggerIncrementalSyncIfPossibleCalls, 2)
    }

    func testImmediateHistoryContinuationStopsAfterDefaultThreeFollowUps() async {
        let syncEngine = MockForegroundSyncEngine()
        let authSession = MockForegroundSyncAuthSession(isAuthenticated: true)
        let coordinator = ForegroundSyncCoordinator(
            syncEngine: syncEngine,
            authSession: authSession,
            periodicInterval: 3_600,
            minimumSyncGap: 3_600
        )
        defer { coordinator.stop(reason: "testCleanup") }

        let firstSliceStarted = expectation(description: "first history slice")
        let secondSliceStarted = expectation(description: "second history slice")
        let thirdSliceStarted = expectation(description: "third history slice")
        let fourthSliceStarted = expectation(description: "fourth history slice")
        syncEngine.onTriggerIncrementalSyncIfPossible = {
            switch syncEngine.triggerIncrementalSyncIfPossibleCalls {
            case 1: firstSliceStarted.fulfill()
            case 2: secondSliceStarted.fulfill()
            case 3: thirdSliceStarted.fulfill()
            case 4: fourthSliceStarted.fulfill()
            default: break
            }
            return .started
        }

        coordinator.start(reason: "appInitialized", triggerImmediateSync: true)
        await fulfillment(of: [firstSliceStarted], timeout: 1.0)

        syncEngine.completeRequest(at: 0, needsFollowUp: true)
        await fulfillment(of: [secondSliceStarted], timeout: 1.0)

        syncEngine.completeRequest(at: 1, needsFollowUp: true)
        await fulfillment(of: [thirdSliceStarted], timeout: 1.0)

        syncEngine.completeRequest(at: 2, needsFollowUp: true)
        await fulfillment(of: [fourthSliceStarted], timeout: 1.0)

        syncEngine.completeRequest(at: 3, needsFollowUp: true)
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(
            syncEngine.triggerIncrementalSyncIfPossibleCalls,
            4,
            "Persistent held progress must fall back to the periodic loop instead of spinning forever"
        )
    }

    func testPostSendSyncForcesRequestInsideMinimumGap() async {
        let syncEngine = MockForegroundSyncEngine()
        let authSession = MockForegroundSyncAuthSession(isAuthenticated: true)
        let coordinator = ForegroundSyncCoordinator(
            syncEngine: syncEngine,
            authSession: authSession,
            periodicInterval: 3_600,
            minimumSyncGap: 3_600
        )
        defer { coordinator.stop(reason: "testCleanup") }

        let initialSyncStarted = expectation(description: "initial sync")
        let postSendSyncStarted = expectation(description: "post-send sync")
        syncEngine.onTriggerIncrementalSyncIfPossible = {
            switch syncEngine.triggerIncrementalSyncIfPossibleCalls {
            case 1: initialSyncStarted.fulfill()
            case 2: postSendSyncStarted.fulfill()
            default: break
            }
            return .started
        }

        coordinator.start(reason: "appInitialized", triggerImmediateSync: true)
        await fulfillment(of: [initialSyncStarted], timeout: 1.0)

        try? await coordinator.performIncrementalSync()

        await fulfillment(of: [postSendSyncStarted], timeout: 1.0)
        XCTAssertEqual(syncEngine.triggerIncrementalSyncIfPossibleCalls, 2)
    }

    func testStart_triggerImmediateSyncWhileLoopRunning_isThrottled() async {
        let syncEngine = MockForegroundSyncEngine()
        let authSession = MockForegroundSyncAuthSession(isAuthenticated: true)
        let coordinator = ForegroundSyncCoordinator(
            syncEngine: syncEngine,
            authSession: authSession,
            periodicInterval: 3_600,
            minimumSyncGap: 90
        )

        defer { coordinator.stop(reason: "testCleanup") }

        let firstSyncExpectation = expectation(description: "first sync")
        syncEngine.onTriggerIncrementalSyncIfPossible = {
            firstSyncExpectation.fulfill()
            return .started
        }

        coordinator.start(reason: "appInitialized", triggerImmediateSync: true)
        await fulfillment(of: [firstSyncExpectation], timeout: 1.0)

        syncEngine.onTriggerIncrementalSyncIfPossible = nil
        coordinator.start(reason: "sceneActive", triggerImmediateSync: true)

        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(syncEngine.triggerIncrementalSyncIfPossibleCalls, 1)
    }

    func testStart_triggerImmediateSyncAfterStop_runsAgain() async {
        let syncEngine = MockForegroundSyncEngine()
        let authSession = MockForegroundSyncAuthSession(isAuthenticated: true)
        let coordinator = ForegroundSyncCoordinator(
            syncEngine: syncEngine,
            authSession: authSession,
            periodicInterval: 3_600,
            minimumSyncGap: 90
        )

        let firstSyncExpectation = expectation(description: "first sync")
        syncEngine.onTriggerIncrementalSyncIfPossible = {
            firstSyncExpectation.fulfill()
            return .started
        }

        coordinator.start(reason: "appInitialized", triggerImmediateSync: true)
        await fulfillment(of: [firstSyncExpectation], timeout: 1.0)

        coordinator.stop(reason: "sceneBackground")

        let secondSyncExpectation = expectation(description: "second sync")
        syncEngine.onTriggerIncrementalSyncIfPossible = {
            secondSyncExpectation.fulfill()
            return .started
        }

        coordinator.start(reason: "sceneActive", triggerImmediateSync: true)
        await fulfillment(of: [secondSyncExpectation], timeout: 1.0)
        XCTAssertEqual(syncEngine.triggerIncrementalSyncIfPossibleCalls, 2)

        coordinator.stop(reason: "testCleanup")
    }

    func testTriggerSyncAfterCurrent_waitsForRealSyncCompletionBoundaryBeforeRunningForcedSync() async {
        let syncEngine = MockForegroundSyncEngine()
        let authSession = MockForegroundSyncAuthSession(isAuthenticated: true)
        let coordinator = ForegroundSyncCoordinator(
            syncEngine: syncEngine,
            authSession: authSession,
            periodicInterval: 3_600,
            minimumSyncGap: 90
        )

        defer { coordinator.stop(reason: "testCleanup") }

        let deferredSyncStarted = expectation(description: "deferred sync started")
        let syncCanFinish = AsyncGate()

        syncEngine.onWaitForCurrentSyncToComplete = {
            await syncCanFinish.wait()
        }
        syncEngine.onTriggerIncrementalSyncIfPossible = {
            deferredSyncStarted.fulfill()
            return .started
        }

        coordinator.triggerSyncAfterCurrent(reason: "appInitializedPostPendingActions", force: true)

        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(syncEngine.waitForCurrentSyncToCompleteCalls, 1)
        XCTAssertEqual(syncEngine.triggerIncrementalSyncIfPossibleCalls, 0)

        await syncCanFinish.open()

        await fulfillment(of: [deferredSyncStarted], timeout: 1.0)
        XCTAssertEqual(syncEngine.triggerIncrementalSyncIfPossibleCalls, 1)
    }

    func testTriggerSyncAfterCurrent_retriesWhenAtomicStartStillReportsInProgress() async {
        let syncEngine = MockForegroundSyncEngine()
        let authSession = MockForegroundSyncAuthSession(isAuthenticated: true)
        let coordinator = ForegroundSyncCoordinator(
            syncEngine: syncEngine,
            authSession: authSession,
            periodicInterval: 3_600,
            minimumSyncGap: 90
        )

        defer { coordinator.stop(reason: "testCleanup") }

        let deferredSyncStarted = expectation(description: "deferred sync started")
        syncEngine.requestResults = [.alreadyInProgress, .started]
        syncEngine.onTriggerIncrementalSyncIfPossible = {
            let result = syncEngine.requestResults.removeFirst()
            if result == .started {
                deferredSyncStarted.fulfill()
            }
            return result
        }

        coordinator.triggerSyncAfterCurrent(reason: "appInitializedPostPendingActions", force: true)

        await fulfillment(of: [deferredSyncStarted], timeout: 1.0)
        XCTAssertEqual(syncEngine.waitForCurrentSyncToCompleteCalls, 2)
        XCTAssertEqual(syncEngine.triggerIncrementalSyncIfPossibleCalls, 2)
    }

    func testPerformUserInitiatedSync_waitsForStartedRefreshToComplete() async {
        let syncEngine = MockForegroundSyncEngine()
        let authSession = MockForegroundSyncAuthSession(isAuthenticated: true)
        let coordinator = ForegroundSyncCoordinator(
            syncEngine: syncEngine,
            authSession: authSession,
            periodicInterval: 3_600,
            minimumSyncGap: 90
        )

        defer { coordinator.stop(reason: "testCleanup") }

        let syncCanFinish = AsyncGate()
        let refreshCompletion = AsyncFlag()
        syncEngine.onWaitForCurrentSyncToComplete = {
            await syncCanFinish.wait()
        }
        syncEngine.onTriggerIncrementalSyncIfPossible = {
            return .started
        }

        let refreshTask = Task {
            await coordinator.performUserInitiatedSync(reason: "pullToRefresh")
            await refreshCompletion.set()
        }

        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(syncEngine.waitForCurrentSyncToCompleteCalls, 1)
        XCTAssertEqual(syncEngine.triggerIncrementalSyncIfPossibleCalls, 1)
        let completedBeforeSyncFinished = await refreshCompletion.get()
        XCTAssertFalse(completedBeforeSyncFinished)

        await syncCanFinish.open()
        await refreshTask.value

        let completedAfterSyncFinished = await refreshCompletion.get()
        XCTAssertTrue(completedAfterSyncFinished)
    }

    func testPerformUserInitiatedSync_waitsForActiveRunThenForcesRefresh() async {
        let syncEngine = MockForegroundSyncEngine()
        let authSession = MockForegroundSyncAuthSession(isAuthenticated: true)
        let coordinator = ForegroundSyncCoordinator(
            syncEngine: syncEngine,
            authSession: authSession,
            periodicInterval: 3_600,
            minimumSyncGap: 90
        )

        defer { coordinator.stop(reason: "testCleanup") }

        let forcedRefreshStarted = expectation(description: "forced refresh started")
        let syncCanFinish = AsyncGate()
        syncEngine.requestResults = [.alreadyInProgress, .started]
        syncEngine.onWaitForCurrentSyncToComplete = {
            await syncCanFinish.wait()
        }
        syncEngine.onTriggerIncrementalSyncIfPossible = {
            let result = syncEngine.requestResults.removeFirst()
            if result == .started {
                forcedRefreshStarted.fulfill()
            }
            return result
        }

        let refreshTask = Task {
            await coordinator.performUserInitiatedSync(reason: "pullToRefresh")
        }

        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(syncEngine.waitForCurrentSyncToCompleteCalls, 1)
        XCTAssertEqual(syncEngine.triggerIncrementalSyncIfPossibleCalls, 1)

        await syncCanFinish.open()
        await fulfillment(of: [forcedRefreshStarted], timeout: 1.0)
        await refreshTask.value

        XCTAssertEqual(syncEngine.waitForCurrentSyncToCompleteCalls, 2)
        XCTAssertEqual(syncEngine.triggerIncrementalSyncIfPossibleCalls, 2)
    }
}

@MainActor
private final class MockForegroundSyncEngine: ForegroundSyncPerforming {
    private typealias Completion = @MainActor @Sendable (Bool) -> Void

    var requestResults: [ForegroundSyncRequestResult] = [.started]
    var onWaitForCurrentSyncToComplete: (() async -> Void)?
    var onTriggerIncrementalSyncIfPossible: (() async -> ForegroundSyncRequestResult)?
    private var completions: [Completion] = []
    private(set) var waitForCurrentSyncToCompleteCalls = 0
    private(set) var triggerIncrementalSyncIfPossibleCalls = 0

    func waitForCurrentSyncToComplete() async {
        waitForCurrentSyncToCompleteCalls += 1
        if let onWaitForCurrentSyncToComplete {
            await onWaitForCurrentSyncToComplete()
        }
    }

    func triggerIncrementalSyncIfPossible(
        completion: @escaping @MainActor @Sendable (Bool) -> Void
    ) async -> ForegroundSyncRequestResult {
        triggerIncrementalSyncIfPossibleCalls += 1
        completions.append(completion)
        if let onTriggerIncrementalSyncIfPossible {
            return await onTriggerIncrementalSyncIfPossible()
        }

        if !requestResults.isEmpty {
            return requestResults.removeFirst()
        }

        return .started
    }

    func completeRequest(at index: Int, needsFollowUp: Bool) {
        completions[index](needsFollowUp)
    }
}

@MainActor
private final class MockForegroundSyncAuthSession: ForegroundSyncAuthenticationProviding {
    var isAuthenticated: Bool
    var requiresReauthentication = false

    var canAccessMailbox: Bool {
        isAuthenticated && !requiresReauthentication
    }

    init(isAuthenticated: Bool) {
        self.isAuthenticated = isAuthenticated
    }
}

private actor AsyncGate {
    private var continuations: [CheckedContinuation<Void, Never>] = []
    private var isOpen = false

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { continuation in
            continuations.append(continuation)
        }
    }

    func open() {
        guard !isOpen else { return }
        isOpen = true
        let pendingContinuations = continuations
        continuations.removeAll()
        pendingContinuations.forEach { $0.resume() }
    }
}

private actor AsyncFlag {
    private var value = false

    func get() -> Bool {
        value
    }

    func set() {
        value = true
    }
}
