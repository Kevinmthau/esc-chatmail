import XCTest
import CoreData
@testable import esc_chatmail

/// Which run boundary the 6-hour store maintenance takes when a `SyncEngine`
/// asks for it.
///
/// HONEST SCOPE: the request is made directly, through
/// `SyncEngine.runStoreMaintenanceAfterSync`. That the engine makes it after
/// an incremental run, and only then, is pinned from source
/// (`StoreMaintenanceAfterSyncSourceTests`), because no suite can drive an
/// incremental sync through the engine.
@MainActor
final class SyncEngineStoreMaintenanceTests: XCTestCase {
    private var testStack: TestCoreDataStack!
    private var scheduleDefaults: UserDefaults!
    private var scheduleSuiteName: String!

    private static let me = "me@example.com"

    override func setUp() async throws {
        try await super.setUp()
        // SQLite: the empty-conversation and duplicate passes use
        // NSBatchDeleteRequest, which an in-memory store rejects.
        testStack = TestCoreDataStack(storeKind: .sqlite)
        scheduleSuiteName = "SyncEngineStoreMaintenanceTests.\(UUID().uuidString)"
        scheduleDefaults = UserDefaults(suiteName: scheduleSuiteName)
    }

    override func tearDown() async throws {
        scheduleDefaults.removePersistentDomain(forName: scheduleSuiteName)
        scheduleDefaults = nil
        scheduleSuiteName = nil
        testStack = nil
        try await super.tearDown()
    }

    // Revert-check: the `StoreMaintenanceCoordinator(syncRunCoordinator:)`
    // that `SyncEngine.init` builds when it is given none. With
    // `StoreMaintenanceCoordinator.shared` in its place the passes take the
    // process-wide boundary: nothing parks behind this engine's own run, and
    // they have run and marked the cadence while that run is still active.
    func testRunStoreMaintenanceAfterSync_takesItsRunOnTheEnginesOwnCoordinator() async throws {
        let syncRunCoordinator = SyncRunCoordinator()
        let engine = makeEngine(syncRunCoordinator: syncRunCoordinator)
        let beganSync = await syncRunCoordinator.beginRun(kind: .foregroundIncremental)
        let syncRun = try XCTUnwrap(beganSync)
        XCTAssertTrue(DataCleanupService.IncrementalCleanupSchedule.isDue(defaults: scheduleDefaults))

        let maintenance = Task { await engine.runStoreMaintenanceAfterSync() }
        let waited = await workIsWaiting(on: syncRunCoordinator)
        XCTAssertTrue(waited, "The maintenance waits for the run this engine's coordinator holds")
        XCTAssertTrue(
            DataCleanupService.IncrementalCleanupSchedule.isDue(defaults: scheduleDefaults),
            "No pass may run while this engine's run is active"
        )

        await syncRunCoordinator.endRun(syncRun)
        await maintenance.value

        XCTAssertFalse(
            DataCleanupService.IncrementalCleanupSchedule.isDue(defaults: scheduleDefaults),
            "The passes ran once the run had ended"
        )
        let stillRunning = await syncRunCoordinator.isRunning()
        XCTAssertFalse(stillRunning, "The maintenance run is ended")
    }

    // MARK: - Helpers

    private func makeEngine(syncRunCoordinator: SyncRunCoordinator) -> SyncEngine {
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
            messageFetcher: MessageFetcher(apiClient: MockGmailAPIClient(), clock: FakeSyncClock()),
            messagePersister: MessagePersister(
                coreDataStack: coreDataStack,
                saveHTML: { _, messageId in .savedWithoutWriting(messageId: messageId) },
                conversationManager: conversationManager
            ),
            historyProcessor: HistoryProcessor(),
            dataCleanupService: cleanupService,
            conversationManager: conversationManager,
            coreDataStack: coreDataStack,
            networkMonitor: NetworkMonitorService(manualStatus: nil),
            syncRunCoordinator: syncRunCoordinator,
            clock: FakeSyncClock()
        )
    }

    /// Whether work parks behind `coordinator`'s boundary within the
    /// deadline. `waitUntilWorkIsWaiting()` awaited bare never returns when
    /// nothing parks: the test must fail on that, not hang.
    private func workIsWaiting(on coordinator: SyncRunCoordinator) async -> Bool {
        let parked = ParkedFlag()
        Task {
            await coordinator.waitUntilWorkIsWaiting()
            await parked.set()
        }
        return await waitUntil(timeout: 5) { await parked.isSet }
    }

    private func waitUntil(
        timeout: TimeInterval,
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

/// Set once work has parked behind a coordinator's boundary.
private actor ParkedFlag {
    private(set) var isSet = false

    func set() {
        isSet = true
    }
}
