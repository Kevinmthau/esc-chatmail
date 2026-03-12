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
}

@MainActor
private final class MockForegroundSyncEngine: ForegroundSyncPerforming {
    var isSyncing = false
    var onPerformIncrementalSync: (() -> Void)?
    private(set) var performIncrementalSyncCalls = 0

    func performIncrementalSync() async throws {
        performIncrementalSyncCalls += 1
        onPerformIncrementalSync?()
    }
}

@MainActor
private final class MockForegroundSyncAuthSession: ForegroundSyncAuthenticationProviding {
    var isAuthenticated: Bool

    init(isAuthenticated: Bool) {
        self.isAuthenticated = isAuthenticated
    }
}
