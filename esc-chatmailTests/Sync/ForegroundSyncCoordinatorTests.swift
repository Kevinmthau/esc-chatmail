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
        syncEngine.onPerformIncrementalSync = {
            syncExpectation.fulfill()
        }

        coordinator.start(reason: "appInitialized", triggerImmediateSync: true)

        await fulfillment(of: [syncExpectation], timeout: 1.0)
        XCTAssertEqual(syncEngine.performIncrementalSyncCalls, 1)
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
        syncEngine.onPerformIncrementalSync = {
            firstSyncExpectation.fulfill()
        }

        coordinator.start(reason: "appInitialized", triggerImmediateSync: true)
        await fulfillment(of: [firstSyncExpectation], timeout: 1.0)

        syncEngine.onPerformIncrementalSync = nil
        coordinator.start(reason: "sceneActive", triggerImmediateSync: true)

        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(syncEngine.performIncrementalSyncCalls, 1)
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
        syncEngine.onPerformIncrementalSync = {
            firstSyncExpectation.fulfill()
        }

        coordinator.start(reason: "appInitialized", triggerImmediateSync: true)
        await fulfillment(of: [firstSyncExpectation], timeout: 1.0)

        coordinator.stop(reason: "sceneBackground")

        let secondSyncExpectation = expectation(description: "second sync")
        syncEngine.onPerformIncrementalSync = {
            secondSyncExpectation.fulfill()
        }

        coordinator.start(reason: "sceneActive", triggerImmediateSync: true)
        await fulfillment(of: [secondSyncExpectation], timeout: 1.0)
        XCTAssertEqual(syncEngine.performIncrementalSyncCalls, 2)

        coordinator.stop(reason: "testCleanup")
    }

    func testTriggerSyncAfterCurrent_waitsForInFlightSyncThenRunsForcedSync() async {
        let syncEngine = MockForegroundSyncEngine()
        let authSession = MockForegroundSyncAuthSession(isAuthenticated: true)
        let coordinator = ForegroundSyncCoordinator(
            syncEngine: syncEngine,
            authSession: authSession,
            periodicInterval: 3_600,
            minimumSyncGap: 90
        )

        defer { coordinator.stop(reason: "testCleanup") }

        let firstSyncStarted = expectation(description: "first sync started")
        let secondSyncStarted = expectation(description: "second sync started")
        let firstSyncCanFinish = AsyncGate()

        syncEngine.onPerformIncrementalSync = {
            if syncEngine.performIncrementalSyncCalls == 1 {
                firstSyncStarted.fulfill()
                await firstSyncCanFinish.wait()
            } else {
                secondSyncStarted.fulfill()
            }
        }

        coordinator.start(reason: "appInitialized", triggerImmediateSync: true)
        await fulfillment(of: [firstSyncStarted], timeout: 1.0)

        coordinator.triggerSyncAfterCurrent(reason: "appInitializedPostPendingActions", force: true)

        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(syncEngine.performIncrementalSyncCalls, 1)

        await firstSyncCanFinish.open()

        await fulfillment(of: [secondSyncStarted], timeout: 1.0)
        XCTAssertEqual(syncEngine.performIncrementalSyncCalls, 2)
    }
}

@MainActor
private final class MockForegroundSyncEngine: ForegroundSyncPerforming {
    var isSyncing = false
    var onPerformIncrementalSync: (() async -> Void)?
    private(set) var performIncrementalSyncCalls = 0

    func performIncrementalSync() async throws {
        isSyncing = true
        performIncrementalSyncCalls += 1
        if let onPerformIncrementalSync {
            await onPerformIncrementalSync()
        }
        isSyncing = false
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
