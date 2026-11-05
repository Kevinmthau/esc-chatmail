import XCTest
import CoreData
import os
@testable import esc_chatmail

/// Below the free-space threshold no run starts, foreground or background, so a full disk can no
/// longer re-fetch the uncommitted backlog every minute (`SyncStorageBackoff`).
///
/// HONEST SCOPE: these pin the admission gate, and the banner and account-transition state through
/// the recorders `SyncEngine.runSyncTask` calls (`recordRunFinished`, `recordRunStoppedOnFullDisk`).
/// That a run's outcome reaches those recorders is covered at its parts (the abort in
/// `IncrementalSyncCursorTests`, the classification in `StorageErrorClassifierTests`, the windows
/// in `SyncStorageBackoffTests`), not end to end through the engine, which would need a full
/// scripted Gmail account.
@MainActor
final class SyncEngineStorageAdmissionTests: XCTestCase {
    private var testStack: TestCoreDataStack!
    private var apiClient: MockGmailAPIClient!

    override func setUp() async throws {
        try await super.setUp()
        testStack = TestCoreDataStack()
        apiClient = MockGmailAPIClient()
    }

    override func tearDown() async throws {
        apiClient = nil
        testStack = nil
        try await super.tearDown()
    }

    private func makeEngine(
        availableBytes: Int64?,
        syncRunCoordinator: SyncRunCoordinator = SyncRunCoordinator()
    ) -> SyncEngine {
        makeEngine(readingAvailableBytes: { availableBytes }, syncRunCoordinator: syncRunCoordinator)
    }

    private func makeEngine(
        readingAvailableBytes: @escaping @Sendable () -> Int64?,
        syncRunCoordinator: SyncRunCoordinator = SyncRunCoordinator()
    ) -> SyncEngine {
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
            attachmentDownloader: AttachmentDownloader.shared,
            networkMonitor: NetworkMonitorService(),
            syncRunCoordinator: syncRunCoordinator,
            clock: FakeSyncClock(),
            availableStorageBytes: readingAvailableBytes
        )
    }

    /// Revert-check: drop the `storageAdmission()` switch from `SyncEngine.prepareIncrementalSync`
    /// and the foreground request answers `.started`.
    func testIncrementalSync_belowTheThreshold_isRefusedBeforeAnyRequest() async {
        let engine = makeEngine(availableBytes: StoreVolumeFreeSpace.lowStorageThresholdBytes - 1)

        let foreground = await engine.triggerIncrementalSyncIfPossible(completion: { _ in
            XCTFail("A refused run must not complete")
        })
        let background = await engine.performIncrementalSyncForBackground(budget: .appRefresh)

        guard case .skippedInsufficientStorage = foreground else {
            return XCTFail("Expected the foreground run to be refused, got \(foreground)")
        }
        XCTAssertEqual(background, .deferredForInsufficientStorage)
        XCTAssertTrue(engine.isBlockedByInsufficientStorage)
        XCTAssertEqual(engine.syncStatus, SyncEngine.insufficientStorageStatus)
        XCTAssertEqual(apiClient.getProfileCallCount, 0, "No request may follow a refusal")
        XCTAssertEqual(apiClient.listHistoryCallCount, 0)
    }

    /// Revert-check: drop the `storageAdmission()` guard from `SyncEngine.performInitialSync` and
    /// the run starts, so the storage status is never published.
    func testInitialSync_belowTheThreshold_isRefusedBeforeAnyRequest() async throws {
        let engine = makeEngine(availableBytes: 0)

        try await engine.performInitialSync()

        XCTAssertTrue(engine.isBlockedByInsufficientStorage)
        XCTAssertEqual(engine.syncStatus, SyncEngine.insufficientStorageStatus)
        XCTAssertEqual(apiClient.getProfileCallCount, 0)
        XCTAssertEqual(apiClient.listMessagesCallCount, 0)
    }

    /// A refusal while another run holds the boundary must not publish: that run may be the one
    /// filling the disk, and clearing `isSyncing` or raising the banner under it hides a run in
    /// progress. The caller hears what the boundary would have said, so the foreground coordinator
    /// queues a request behind the run, and that request meets the storage gate once it ends.
    /// Revert-check: the `isBoundaryHeld()` guard in `SyncEngine.storageAdmission` (the foreground
    /// request then answers `.skippedInsufficientStorage` and `isSyncing` drops to false).
    func testIncrementalSync_belowTheThresholdWhileARunIsActive_reportsInProgressAndPublishesNothing() async throws {
        let coordinator = SyncRunCoordinator()
        let engine = makeEngine(
            availableBytes: StoreVolumeFreeSpace.lowStorageThresholdBytes - 1,
            syncRunCoordinator: coordinator
        )
        let beganRun = await coordinator.beginRun(kind: .maintenance)
        let activeRun = try XCTUnwrap(beganRun)
        engine.uiState.update(isSyncing: true, status: "Syncing...")

        let foreground = await engine.triggerIncrementalSyncIfPossible(completion: { _ in
            XCTFail("A refused run must not complete")
        })
        let background = await engine.performIncrementalSyncForBackground(budget: .appRefresh)

        guard case .alreadyInProgress = foreground else {
            return XCTFail("Expected the boundary's answer while a run is active, got \(foreground)")
        }
        XCTAssertEqual(background, .blocked(by: .maintenance))
        XCTAssertFalse(engine.isBlockedByInsufficientStorage, "No banner over a run in progress")
        XCTAssertTrue(engine.isSyncing, "The active run's state must not be overwritten")
        XCTAssertEqual(engine.syncStatus, "Syncing...")

        await coordinator.endRun(activeRun)
        let afterRun = await engine.triggerIncrementalSyncIfPossible(completion: { _ in
            XCTFail("A refused run must not complete")
        })
        guard case .skippedInsufficientStorage = afterRun else {
            return XCTFail("Once the boundary is free the refusal is published, got \(afterRun)")
        }
        XCTAssertTrue(engine.isBlockedByInsufficientStorage)
        XCTAssertEqual(apiClient.getProfileCallCount, 0)
        XCTAssertEqual(apiClient.listHistoryCallCount, 0)
    }

    /// A run with no new mail succeeds on a disk still too full for message bodies. Lifting the
    /// banner on it hid the full disk until the next real message raised it again.
    /// Revert-check: the `liftsInsufficientStorageBanner` guard in `SyncEngine.recordRunFinished`
    /// (back to an unconditional `setBlockedByInsufficientStorage(false)`, the first run that
    /// stored nothing lifts the banner).
    func testRecordRunFinished_afterAFullDiskStop_keepsTheBannerUntilSpaceIsFreed() {
        let threshold = StoreVolumeFreeSpace.lowStorageThresholdBytes
        let atStop: Int64 = 300 * 1024 * 1024
        let reading = OSAllocatedUnfairLock<Int64?>(initialState: atStop)
        let engine = makeEngine(readingAvailableBytes: { reading.withLock { $0 } })

        engine.recordRunStoppedOnFullDisk()
        XCTAssertTrue(engine.isBlockedByInsufficientStorage)

        engine.recordRunFinished()
        XCTAssertTrue(
            engine.isBlockedByInsufficientStorage,
            "A run that stored nothing proves nothing about a disk that just stopped a run"
        )

        reading.withLock { $0 = atStop + threshold }
        engine.recordRunFinished()
        XCTAssertFalse(engine.isBlockedByInsufficientStorage, "Freed space lifts it")
    }

    /// `SyncEngine.shared` outlives sign-out: the previous account's backoff window and banner
    /// used to greet the next account.
    /// Revert-check: the body of `SyncEngine.resetStorageStateForAccountTransition()` (the banner
    /// and the backoff both survive the call).
    func testResetStorageStateForAccountTransition_forgetsTheBackoffAndTheBanner() {
        let engine = makeEngine(availableBytes: 300 * 1024 * 1024)
        engine.recordRunStoppedOnFullDisk()
        XCTAssertTrue(engine.isBlockedByInsufficientStorage)
        XCTAssertNotEqual(engine.storageBackoff, SyncStorageBackoff())

        engine.resetStorageStateForAccountTransition()

        XCTAssertFalse(engine.isBlockedByInsufficientStorage)
        XCTAssertEqual(engine.storageBackoff, SyncStorageBackoff())
    }
}
