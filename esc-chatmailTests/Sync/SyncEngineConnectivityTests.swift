import XCTest
import Network
@testable import esc_chatmail

/// The preflight a run meets before it takes the boundary: a path known to be
/// unsatisfied skips it, and nothing else does (architecture review 2026-11,
/// background-energy#5).
///
/// The skip is kept on purpose: the read session waits for connectivity
/// itself, so a run started offline would hold the exclusive boundary for
/// minutes. A run that starts here is real and stops at once: the store is
/// empty, its initial-sync fallback's first Gmail request fails.
///
/// HONEST SCOPE: the path is manual. What a real VPN On Demand tunnel or a
/// Mac at wake reports was not measured.
@MainActor
final class SyncEngineConnectivityTests: XCTestCase {
    private static let cleanupKey = "hasDoneDuplicateCleanupV1"

    private var testStack: TestCoreDataStack!
    private var apiClient: MockGmailAPIClient!
    private var previousCleanupFlag: Any?

    override func setUp() async throws {
        try await super.setUp()
        testStack = TestCoreDataStack()
        apiClient = MockGmailAPIClient()
        // The one-time duplicate cleanup reads and writes the standard
        // defaults; marked done, it is skipped, and put back after.
        previousCleanupFlag = UserDefaults.standard.object(forKey: Self.cleanupKey)
        UserDefaults.standard.set(true, forKey: Self.cleanupKey)
    }

    override func tearDown() async throws {
        if let previousCleanupFlag {
            UserDefaults.standard.set(previousCleanupFlag, forKey: Self.cleanupKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.cleanupKey)
        }
        previousCleanupFlag = nil
        apiClient = nil
        testStack = nil
        try await super.tearDown()
    }

    // Revert-check: the `guard networkMonitor.isPathUsable` in
    // `SyncEngine.prepareIncrementalSync` (both runs start, offline).
    func testIncrementalSync_onAKnownUnsatisfiedPath_isSkippedBeforeAnyRequest() async {
        let coordinator = SyncRunCoordinator()
        let engine = makeEngine(path: NetworkMonitorService(manualStatus: .unsatisfied), coordinator: coordinator)
        // Were a run to start, it would stop at its first request.
        apiClient.getProfileError = APIError.timeout

        let foreground = await engine.triggerIncrementalSyncIfPossible(completion: { _ in
            XCTFail("A skipped run must not complete")
            return false
        })
        let background = await engine.performIncrementalSyncForBackground(budget: .processing)

        guard case .skippedNoNetwork = foreground else {
            return XCTFail("Expected the run to be skipped, got \(foreground)")
        }
        XCTAssertEqual(background, .failed)
        XCTAssertEqual(engine.syncStatus, "Network unavailable")
        XCTAssertEqual(apiClient.getProfileCallCount, 0, "No request on a path known to be down")
        let isRunning = await coordinator.isRunning()
        XCTAssertFalse(isRunning, "The boundary was never taken")
    }

    /// An idle VPN On Demand tunnel reports `.requiresConnection` and comes up
    /// on the request itself; before the first update the path is unknown.
    /// Neither is a path known to be down.
    ///
    /// Revert-check: `NetworkMonitorService.isUsable`'s
    /// `OutboundNetworkPathMonitor.isUsable` (as `status == .satisfied`, the
    /// tunnel's run is skipped) and its `guard let status else { return true }`
    /// (as `false`, the run before any update is skipped).
    func testIncrementalSync_onAPathThatRequiresAConnectionOrIsNotReportedYet_starts() async {
        for status in [NWPath.Status.requiresConnection, nil] {
            let coordinator = SyncRunCoordinator()
            let engine = makeEngine(path: NetworkMonitorService(manualStatus: status), coordinator: coordinator)
            apiClient.getProfileError = APIError.timeout

            let request = await engine.triggerIncrementalSyncIfPossible(completion: { _ in
                XCTFail("A failed run must not complete")
                return false
            })

            guard case .started = request else {
                XCTFail("Expected a run to start on \(String(describing: status)), got \(request)")
                continue
            }
            let ended = await waitUntil { await !coordinator.isRunning() }
            XCTAssertTrue(ended, String(describing: status))
        }
    }

    /// Revert-check: the status written in
    /// `NetworkMonitorService.pathDidChange(to:isExpensive:)` (the path stays
    /// unsatisfied and the second run is skipped).
    func testIncrementalSync_afterThePathComesBack_starts() async {
        let path = NetworkMonitorService(manualStatus: .unsatisfied)
        let coordinator = SyncRunCoordinator()
        let engine = makeEngine(path: path, coordinator: coordinator)
        apiClient.getProfileError = APIError.timeout
        let skipped = await engine.triggerIncrementalSyncIfPossible(completion: { _ in false })
        guard case .skippedNoNetwork = skipped else { return XCTFail("Expected a skip, got \(skipped)") }

        path.pathDidChange(to: .satisfied)
        let request = await engine.triggerIncrementalSyncIfPossible(completion: { _ in
            XCTFail("A failed run must not complete")
            return false
        })

        guard case .started = request else { return XCTFail("Expected a run to start, got \(request)") }
        let ended = await waitUntil { await !coordinator.isRunning() }
        XCTAssertTrue(ended)
    }

    // MARK: - Helpers

    private func makeEngine(path: NetworkMonitorService, coordinator: SyncRunCoordinator) -> SyncEngine {
        let coreDataStack = CoreDataStack(persistentContainerForTesting: testStack.persistentContainer)
        let conversationManager = ConversationManager(currentUserEmail: { "me@example.com" })
        return SyncEngine(
            messageFetcher: MessageFetcher(apiClient: apiClient, clock: FakeSyncClock()),
            messagePersister: MessagePersister(
                coreDataStack: coreDataStack,
                saveHTML: { _, messageId in .savedWithoutWriting(messageId: messageId) },
                conversationManager: conversationManager
            ),
            historyProcessor: HistoryProcessor(),
            dataCleanupService: DataCleanupService(),
            conversationManager: conversationManager,
            coreDataStack: coreDataStack,
            networkMonitor: path,
            syncRunCoordinator: coordinator,
            clock: FakeSyncClock(),
            // The disk this test runs on is no part of it.
            availableStorageBytes: { StoreVolumeFreeSpace.lowStorageThresholdBytes * 100 }
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
