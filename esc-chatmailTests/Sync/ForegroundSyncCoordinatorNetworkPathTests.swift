import XCTest
@testable import esc_chatmail

/// A path that comes back starts a foreground sync, through the coordinator's
/// own gate, and only while its session runs (architecture review 2026-11,
/// background-energy#5). It used to wait for the next 60-second tick.
///
/// HONEST SCOPE: the path is manual and the engine a mock. When a real Mac
/// reports its path after wake, or an iPhone after airplane mode, was not
/// measured.
@MainActor
final class ForegroundSyncCoordinatorNetworkPathTests: XCTestCase {

    /// Revert-check: the `startUsablePathObservation()` call in
    /// `ForegroundSyncCoordinator.start(reason:triggerImmediateSync:)` (the
    /// return is never heard and only the first sync is asked for).
    func testUsablePathReturn_afterASkippedSync_startsOneSync() async {
        let path = NetworkMonitorService(manualStatus: .unsatisfied)
        let syncEngine = MockForegroundSyncEngine()
        syncEngine.requestResults = [.skippedNoNetwork, .started]
        let coordinator = makeCoordinator(syncEngine: syncEngine, path: path)
        defer { coordinator.stop(reason: "testCleanup") }

        coordinator.start(reason: "appInitialized", triggerImmediateSync: true)
        let skipped = await waitUntil { syncEngine.triggerIncrementalSyncIfPossibleCalls == 1 }
        XCTAssertTrue(skipped)

        path.pathDidChange(to: .satisfied)

        let resumed = await waitUntil { syncEngine.triggerIncrementalSyncIfPossibleCalls == 2 }
        XCTAssertTrue(resumed, "The return asks for a sync at once")
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(syncEngine.triggerIncrementalSyncIfPossibleCalls, 2, "One sync for one return")
    }

    /// The return goes through `triggerSync(force: false)`: a link that flaps
    /// right after a sync started waits for the minimum gap like any trigger.
    ///
    /// Revert-check: the `force: false` the coordinator's observation passes
    /// to `triggerSync` (as `true`, a second sync starts inside the gap).
    func testUsablePathReturn_withinTheMinimumGap_startsNothing() async {
        let path = NetworkMonitorService(manualStatus: .satisfied)
        let syncEngine = MockForegroundSyncEngine()
        let coordinator = makeCoordinator(syncEngine: syncEngine, path: path)
        defer { coordinator.stop(reason: "testCleanup") }

        coordinator.start(reason: "appInitialized", triggerImmediateSync: true)
        let started = await waitUntil { syncEngine.triggerIncrementalSyncIfPossibleCalls == 1 }
        XCTAssertTrue(started)

        path.pathDidChange(to: .unsatisfied)
        path.pathDidChange(to: .satisfied)
        try? await Task.sleep(nanoseconds: 150_000_000)

        XCTAssertEqual(syncEngine.triggerIncrementalSyncIfPossibleCalls, 1)
    }

    /// A stopped session (the iOS app in the background, a Mac asleep, a
    /// sign-out) starts no sync when the path returns, and a session started
    /// again hears returns again.
    ///
    /// Revert-check (combined): the `usablePathTask?.cancel()` in
    /// `ForegroundSyncCoordinator.stop(reason:)` together with the
    /// `periodicTask != nil` guard in its observation (a sync starts after
    /// stop). HONEST SCOPE: each alone keeps a stopped session from syncing,
    /// so no single-line revert fails the first half; the `usablePathTask =
    /// nil` in `stop` fails the second (the restarted session never
    /// subscribes again).
    func testUsablePathReturn_afterStop_startsNothingUntilStartedAgain() async {
        let path = NetworkMonitorService(manualStatus: .unsatisfied)
        let syncEngine = MockForegroundSyncEngine()
        syncEngine.requestResults = [.skippedNoNetwork, .skippedNoNetwork, .started]
        let coordinator = makeCoordinator(syncEngine: syncEngine, path: path)
        defer { coordinator.stop(reason: "testCleanup") }
        coordinator.start(reason: "appInitialized", triggerImmediateSync: true)
        let skipped = await waitUntil { syncEngine.triggerIncrementalSyncIfPossibleCalls == 1 }
        XCTAssertTrue(skipped)

        coordinator.stop(reason: "sceneDidEnterBackground")
        path.pathDidChange(to: .satisfied)
        try? await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(syncEngine.triggerIncrementalSyncIfPossibleCalls, 1, "Nothing after stop")

        path.pathDidChange(to: .unsatisfied)
        coordinator.start(reason: "applicationDidBecomeActive", triggerImmediateSync: true)
        let restarted = await waitUntil { syncEngine.triggerIncrementalSyncIfPossibleCalls == 2 }
        XCTAssertTrue(restarted)
        path.pathDidChange(to: .satisfied)
        let resumed = await waitUntil { syncEngine.triggerIncrementalSyncIfPossibleCalls == 3 }
        XCTAssertTrue(resumed, "The restarted session hears the return")
    }

    // MARK: - Helpers

    private func makeCoordinator(
        syncEngine: MockForegroundSyncEngine,
        path: NetworkMonitorService
    ) -> ForegroundSyncCoordinator {
        ForegroundSyncCoordinator(
            syncEngine: syncEngine,
            authSession: SignedInSession(),
            networkPath: path,
            periodicInterval: 3_600,
            minimumSyncGap: 90
        )
    }

    private func waitUntil(
        timeout: TimeInterval = 5,
        pollIntervalNanoseconds: UInt64 = 5_000_000,
        condition: () async -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return true }
            try? await Task.sleep(nanoseconds: pollIntervalNanoseconds)
        }
        return await condition()
    }
}

@MainActor
private final class SignedInSession: ForegroundSyncAuthenticationProviding {
    let canAccessMailbox = true
}
