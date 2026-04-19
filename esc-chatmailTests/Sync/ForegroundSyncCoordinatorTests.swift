import XCTest
@testable import esc_chatmail

@MainActor
final class ForegroundSyncCoordinatorTests: XCTestCase {
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
}

@MainActor
private final class MockForegroundSyncEngine: ForegroundSyncPerforming {
    var requestResults: [ForegroundSyncRequestResult] = [.started]
    var onWaitForCurrentSyncToComplete: (() async -> Void)?
    var onTriggerIncrementalSyncIfPossible: (() async -> ForegroundSyncRequestResult)?
    private(set) var waitForCurrentSyncToCompleteCalls = 0
    private(set) var triggerIncrementalSyncIfPossibleCalls = 0

    func waitForCurrentSyncToComplete() async {
        waitForCurrentSyncToCompleteCalls += 1
        if let onWaitForCurrentSyncToComplete {
            await onWaitForCurrentSyncToComplete()
        }
    }

    func triggerIncrementalSyncIfPossible() async -> ForegroundSyncRequestResult {
        triggerIncrementalSyncIfPossibleCalls += 1
        if let onTriggerIncrementalSyncIfPossible {
            return await onTriggerIncrementalSyncIfPossible()
        }

        if !requestResults.isEmpty {
            return requestResults.removeFirst()
        }

        return .started
    }
}

@MainActor
private final class MockForegroundSyncAuthSession: ForegroundSyncAuthenticationProviding {
    var isAuthenticated: Bool

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
