import XCTest
import CoreData
@testable import esc_chatmail

/// What each entry's run holds the boundary as, and the background time a
/// foreground-entry run holds until its chain ends (architecture review
/// 2026-11, background-energy#2, startup-lifecycle#3).
///
/// The run is real: the engine's own orchestrators over an empty store, which
/// fall back to an initial sync, and that waits in its first Gmail request
/// (`MockGmailAPIClient.artificialDelay`) until it is cancelled.
///
/// HONEST SCOPE: the lease's manager is a spy. Whether UIKit grants the time,
/// when it expires a grant, and what iOS suspension and background-task
/// delivery actually do cannot be observed on a simulator. No run through the
/// engine can succeed here (the incremental orchestrator asks
/// `AuthSession.shared` for the account once one is stored), so the chain's
/// cancellation reaching the store maintenance after a successful run is
/// pinned from source (`SyncRunLeaseSourceTests`).
@MainActor
final class SyncEngineRunLeaseTests: XCTestCase {
    private static let me = "me@example.com"
    private static let cleanupKey = "hasDoneDuplicateCleanupV1"

    private var testStack: TestCoreDataStack!
    private var apiClient: MockGmailAPIClient!
    private var scheduleDefaults: UserDefaults!
    private var scheduleSuiteName: String!
    private var previousCleanupFlag: Any?

    override func setUp() async throws {
        try await super.setUp()
        testStack = TestCoreDataStack()
        apiClient = MockGmailAPIClient()
        // Long enough that only a cancellation ends the run inside a test.
        apiClient.artificialDelay = 60
        scheduleSuiteName = "SyncEngineRunLeaseTests.\(UUID().uuidString)"
        scheduleDefaults = UserDefaults(suiteName: scheduleSuiteName)
        // The initial sync's one-time duplicate cleanup reads and writes the
        // standard defaults; marked done, it is skipped, and put back after.
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
        scheduleDefaults.removePersistentDomain(forName: scheduleSuiteName)
        scheduleDefaults = nil
        scheduleSuiteName = nil
        apiClient = nil
        testStack = nil
        try await super.tearDown()
    }

    // MARK: - Run kind

    // Revert-check: the `kind: .background` that
    // `SyncEngine.performIncrementalSyncForBackground` passes to
    // `prepareIncrementalSync` (as `.foregroundIncremental`, the run holds the
    // boundary as a foreground run, and a second wake reads it as stale).
    func testPerformIncrementalSyncForBackground_whileRunning_holdsTheBoundaryAsBackground() async throws {
        let coordinator = SyncRunCoordinator()
        let lease = SyncRunBackgroundTaskManagerSpy()
        let engine = makeEngine(syncRunCoordinator: coordinator, runBackgroundTaskManager: lease)

        let backgroundRun = Task { await engine.performIncrementalSyncForBackground(budget: .processing) }
        let started = await waitUntil { self.apiClient.getProfileCallCount == 1 }
        XCTAssertTrue(started, "The run reached its first request")

        let activeKind = await coordinator.activeRunKind()
        XCTAssertEqual(activeKind, .background)
        let secondWake = await engine.performIncrementalSyncForBackground(budget: .appRefresh)
        XCTAssertEqual(secondWake, .blocked(by: .background), "Another wake is covered by this one")
        XCTAssertEqual(lease.beginCount, 0, "A background task's run is the task's own; it takes no lease")

        backgroundRun.cancel()
        _ = await backgroundRun.value
        let isRunning = await coordinator.isRunning()
        XCTAssertFalse(isRunning)
    }

    // Revert-check: the `kind: .foregroundIncremental` that
    // `SyncEngine.triggerIncrementalSyncIfPossible` passes to
    // `prepareIncrementalSync` (as `.background`, a wake beside a frozen
    // foreground run reads as covered and schedules no catch-up).
    func testTriggerIncrementalSync_whileRunning_holdsTheBoundaryAsForegroundIncremental() async throws {
        let coordinator = SyncRunCoordinator()
        let lease = SyncRunBackgroundTaskManagerSpy()
        let engine = makeEngine(syncRunCoordinator: coordinator, runBackgroundTaskManager: lease)

        let request = await engine.triggerIncrementalSyncIfPossible(completion: { _ in
            XCTFail("A cancelled run must not complete")
            return false
        })
        guard case .started = request else { return XCTFail("Expected a run to start, got \(request)") }
        let started = await waitUntil { self.apiClient.getProfileCallCount == 1 }
        XCTAssertTrue(started)

        let activeKind = await coordinator.activeRunKind()
        XCTAssertEqual(activeKind, .foregroundIncremental)
        let wake = await engine.performIncrementalSyncForBackground(budget: .appRefresh)
        XCTAssertEqual(wake, .blocked(by: .foregroundIncremental))

        lease.expire()
        let ended = await waitUntil { await !coordinator.isRunning() }
        XCTAssertTrue(ended)
    }

    // MARK: - Lease

    /// The lease is taken in the turn the run is admitted and kept until the
    /// chain has ended, after the run's `endRun`: `runSyncTask` publishes the
    /// cancelled status after `endRun`, so a lease ended before it sees
    /// another status.
    ///
    /// Revert-check: the `lease.begin { … }` call in
    /// `SyncEngine.triggerIncrementalSyncIfPossible` (no lease is begun), and
    /// its `defer { lease.end() }` (the lease is never ended by the chain).
    func testTriggerIncrementalSync_admittedRun_holdsALeaseFromAdmissionUntilTheChainEnds() async throws {
        let coordinator = SyncRunCoordinator()
        let lease = SyncRunBackgroundTaskManagerSpy()
        let engine = makeEngine(syncRunCoordinator: coordinator, runBackgroundTaskManager: lease)
        var statusWhenEnded: String?
        lease.onEnd = { statusWhenEnded = engine.syncStatus }

        let request = await engine.triggerIncrementalSyncIfPossible(completion: { _ in
            XCTFail("A cancelled run must not complete")
            return false
        })

        guard case .started = request else { return XCTFail("Expected a run to start, got \(request)") }
        XCTAssertEqual(lease.beginCount, 1, "Begun before the request returned")
        let started = await waitUntil { self.apiClient.getProfileCallCount == 1 }
        XCTAssertTrue(started)
        XCTAssertEqual(lease.endCount, 0, "Held while the run is in flight")

        let cancelled = await coordinator.cancelForegroundRun()
        XCTAssertTrue(cancelled)
        let leaseEnded = await waitUntil { lease.endCount == 1 }

        XCTAssertTrue(leaseEnded, "The chain ends the lease")
        XCTAssertEqual(lease.endedIdentifiers, [lease.grantedIdentifier])
        XCTAssertEqual(statusWhenEnded, "Sync cancelled", "Ended after the run had ended")
        let isRunning = await coordinator.isRunning()
        XCTAssertFalse(isRunning)
    }

    /// UIKit's expiration cancels the run and ends the lease before it
    /// returns, awaiting nothing; the run then unwinds and releases the
    /// boundary.
    ///
    /// Revert-check: the `syncRunTask.task.cancel()` in the expiration that
    /// `SyncEngine.triggerIncrementalSyncIfPossible` gives the lease (the run
    /// waits out its request and the boundary stays held past the deadline),
    /// and the `self.end()` in `SyncRunBackgroundLease.begin`'s expiration
    /// handler (the grant is ended only once the chain unwinds).
    ///
    /// HONEST SCOPE: what a cancelled run leaves in the store is not pinned
    /// here. The run is cancelled in its first request, before it has staged
    /// anything, so the store would be empty whether or not the cancellation
    /// rolled anything back; an assertion that no account was stored could
    /// not fail. `IncrementalSyncCursorTests`
    /// (`testCancellationDuringMessageFetchRetainsCheckpointAndFreshRunResumes`)
    /// pins that a cancelled run leaves the cursor, the checkpoint and the
    /// failure counter as they were.
    func testTriggerIncrementalSync_leaseExpiration_cancelsTheRunAndEndsTheLeaseAtOnce() async throws {
        let coordinator = SyncRunCoordinator()
        let lease = SyncRunBackgroundTaskManagerSpy()
        let engine = makeEngine(syncRunCoordinator: coordinator, runBackgroundTaskManager: lease)
        let request = await engine.triggerIncrementalSyncIfPossible(completion: { _ in
            XCTFail("A cancelled run must not complete")
            return false
        })
        guard case .started = request else { return XCTFail("Expected a run to start, got \(request)") }
        let started = await waitUntil { self.apiClient.getProfileCallCount == 1 }
        XCTAssertTrue(started)

        lease.expire()

        XCTAssertEqual(lease.endCount, 1, "Ended inside the expiration handler")
        let unwound = await waitUntil(timeout: 10) { await !coordinator.isRunning() }
        XCTAssertTrue(unwound, "The cancelled run released the boundary")
        XCTAssertEqual(lease.endCount, 1, "Ended once: the chain's own end is a no-op")
        XCTAssertEqual(engine.syncStatus, "Sync cancelled")
        XCTAssertFalse(engine.isSyncing)
    }

    // MARK: - Helpers

    private func makeEngine(
        syncRunCoordinator: SyncRunCoordinator,
        runBackgroundTaskManager: any SyncRunBackgroundTaskManaging
    ) -> SyncEngine {
        let coreDataStack = CoreDataStack(persistentContainerForTesting: testStack.persistentContainer)
        let me = Self.me
        let conversationManager = ConversationManager(currentUserEmail: { me })
        let flags = InMemoryMigrationFlagStore()
        flags.set(true, forKey: DataCleanupService.participantSetSplitMigrationKey)
        flags.set(true, forKey: DataCleanupService.rfc2047HeaderTextRepairKey)
        let cleanupService = DataCleanupService(
            coreDataStack: coreDataStack,
            conversationManager: conversationManager,
            conversationMutationSerializer: ConversationRollupMutationSerializer(),
            migrationFlags: flags,
            identityAliasProvider: { _ in [me] },
            maintenanceScheduleDefaults: scheduleDefaults,
            announceCleanupFinished: {}
        )
        return SyncEngine(
            messageFetcher: MessageFetcher(apiClient: apiClient, clock: FakeSyncClock()),
            messagePersister: MessagePersister(
                coreDataStack: coreDataStack,
                saveHTML: { _, messageId in .savedWithoutWriting(messageId: messageId) },
                conversationManager: conversationManager
            ),
            historyProcessor: HistoryProcessor(),
            dataCleanupService: cleanupService,
            conversationManager: conversationManager,
            coreDataStack: coreDataStack,
            networkMonitor: NetworkMonitorService(),
            syncRunCoordinator: syncRunCoordinator,
            clock: FakeSyncClock(),
            // The disk this test runs on is no part of it.
            availableStorageBytes: { StoreVolumeFreeSpace.lowStorageThresholdBytes * 100 },
            runBackgroundTaskManager: runBackgroundTaskManager
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
