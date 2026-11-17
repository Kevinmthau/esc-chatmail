import XCTest
@testable import esc_chatmail

@MainActor
final class StoreMaintenanceCoordinatorTests: XCTestCase {
    func testRunExclusivelyWhenStoreIsIdle_preservesBodyWrittenBeforeMessageCommit() async throws {
        let stack = TestCoreDataStack()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("StoreMaintenanceCoordinatorTests-\(UUID().uuidString)", isDirectory: true)
        let handler = HTMLContentHandler(messagesDirectory: directory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let syncRunCoordinator = SyncRunCoordinator()
        let coordinator = StoreMaintenanceCoordinator(
            syncRunCoordinator: syncRunCoordinator,
            remoteConfig: StaticRemoteConfigProvider(
                flags: [.databaseMaintenanceEnabled: true]
            )
        )

        guard let activeSync = await syncRunCoordinator.beginRun(kind: .foregroundInitial) else {
            return XCTFail("Expected the initial sync run to start")
        }
        let bodyURL = try XCTUnwrap(handler.saveHTML("<p>new message</p>", for: "new-message"))

        let maintenance = Task {
            await coordinator.runExclusivelyWhenStoreIsIdle(operationName: "test cleanup") {
                let generation = handler.captureAccountGeneration()
                await DatabaseMaintenanceService.cleanupOrphanedHTMLFiles(
                    in: stack.viewContext,
                    htmlContentHandler: handler,
                    expectedGeneration: generation
                )
                return true
            }
        }
        await syncRunCoordinator.waitUntilWorkIsWaiting()

        await stack.viewContext.perform {
            _ = MessageBuilder().withId("new-message").build(in: stack.viewContext)
        }
        do {
            try stack.saveViewContext()
        } catch {
            await syncRunCoordinator.endRun(activeSync)
            _ = await maintenance.value
            throw error
        }
        await syncRunCoordinator.endRun(activeSync)

        let succeeded = await maintenance.value
        XCTAssertTrue(succeeded)
        XCTAssertTrue(FileManager.default.fileExists(atPath: bodyURL.path))
        XCTAssertEqual(handler.loadHTML(for: "new-message"), "<p>new message</p>")
    }

    // Revert-check: waitUntilIdle() alone leaves a gap where a new sync can
    // start after the idle check and write HTML before its Message row commits.
    func testRunExclusivelyWhenStoreIsIdle_ownsSyncBoundaryUntilOperationFinishes() async {
        let syncRunCoordinator = SyncRunCoordinator()
        let coordinator = StoreMaintenanceCoordinator(
            syncRunCoordinator: syncRunCoordinator,
            remoteConfig: StaticRemoteConfigProvider(
                flags: [.databaseMaintenanceEnabled: true]
            )
        )
        let operationStarted = expectation(description: "maintenance operation started")
        let operationCanFinish = AsyncGate()

        guard let activeSync = await syncRunCoordinator.beginRun(kind: .foregroundInitial) else {
            return XCTFail("Expected the initial sync run to start")
        }

        let maintenance = Task {
            await coordinator.runExclusivelyWhenStoreIsIdle(operationName: "test cleanup") {
                operationStarted.fulfill()
                await operationCanFinish.wait()
                return true
            }
        }

        await syncRunCoordinator.waitUntilWorkIsWaiting()
        await syncRunCoordinator.endRun(activeSync)
        await fulfillment(of: [operationStarted], timeout: 1.0)

        let activeKind = await syncRunCoordinator.activeRunKind()
        XCTAssertEqual(activeKind, .maintenance)
        let overlappingSync = await syncRunCoordinator.beginRun(kind: .background)
        XCTAssertNil(overlappingSync, "Sync must not overlap store maintenance")

        await operationCanFinish.open()
        let succeeded = await maintenance.value
        XCTAssertTrue(succeeded)
        let isRunning = await syncRunCoordinator.isRunning()
        XCTAssertFalse(isRunning)
    }

    func testRunExclusivelyWhenStoreIsIdle_dropsQueuedOperationAfterAccountTransition() async {
        let syncRunCoordinator = SyncRunCoordinator()
        let coordinator = StoreMaintenanceCoordinator(
            syncRunCoordinator: syncRunCoordinator,
            remoteConfig: StaticRemoteConfigProvider(
                flags: [.databaseMaintenanceEnabled: true]
            )
        )
        let operationRan = AsyncFlag()

        guard let activeSync = await syncRunCoordinator.beginRun(kind: .foregroundInitial) else {
            return XCTFail("Expected the initial sync run to start")
        }

        let maintenance = Task {
            await coordinator.runExclusivelyWhenStoreIsIdle(operationName: "test cleanup") {
                await operationRan.set()
                return true
            }
        }
        await syncRunCoordinator.waitUntilWorkIsWaiting()

        let transition = Task {
            await syncRunCoordinator.beginQuiescence()
        }
        while await syncRunCoordinator.makeAccountWorkRequest() != nil {
            await Task.yield()
        }

        await syncRunCoordinator.endRun(activeSync)
        await transition.value
        await syncRunCoordinator.endQuiescence()

        let succeeded = await maintenance.value
        let didRunOperation = await operationRan.value
        XCTAssertFalse(succeeded)
        XCTAssertFalse(didRunOperation)
    }

    // MARK: - Cancelling a running operation

    // Revert-check: `acquireRunWithTask` in
    // `StoreMaintenanceCoordinator.resultOfExclusiveRun`. Taken
    // with `acquireRun`, the run has no task, `beginQuiescence()` has nothing
    // to cancel, and a sign-out waits for the whole operation: here the
    // operation runs to its own deadline and never sees a cancellation.
    func testBeginQuiescence_cancelsTheRunningOperationAndWaitsForItToEnd() async {
        let syncRunCoordinator = SyncRunCoordinator()
        let coordinator = StoreMaintenanceCoordinator(syncRunCoordinator: syncRunCoordinator)
        let operationStarted = expectation(description: "maintenance operation started")
        let sawCancellation = AsyncFlag()
        let operationEnded = AsyncFlag()

        let maintenance = Task {
            await coordinator.runExclusivelyWhenStoreIsIdle(operationName: "test cleanup") {
                operationStarted.fulfill()
                if await Self.waitForCancellation(deadline: 5) {
                    await sawCancellation.set()
                }
                await operationEnded.set()
                return true
            }
        }
        await fulfillment(of: [operationStarted], timeout: 2)

        await syncRunCoordinator.beginQuiescence()

        let endedBeforeQuiescenceReturned = await operationEnded.value
        XCTAssertTrue(endedBeforeQuiescenceReturned, "Quiescence still drains the run it cancelled")
        let cancelled = await sawCancellation.value
        XCTAssertTrue(cancelled, "An account transition cancels a running maintenance operation")
        let isRunning = await syncRunCoordinator.isRunning()
        XCTAssertFalse(isRunning)
        await syncRunCoordinator.endQuiescence()
        _ = await maintenance.value
    }

    // Revert-check: the `withTaskCancellationHandler` in
    // `StoreMaintenanceCoordinator.resultOfExclusiveRun`. The
    // operation runs in a task of its own, so without the handler the
    // cancellation of the caller, which is how a background task's
    // expiration arrives, stops nothing.
    func testCancellingTheCaller_cancelsTheRunningOperation() async {
        let syncRunCoordinator = SyncRunCoordinator()
        let coordinator = StoreMaintenanceCoordinator(syncRunCoordinator: syncRunCoordinator)
        let operationStarted = expectation(description: "maintenance operation started")
        let sawCancellation = AsyncFlag()

        let maintenance = Task {
            await coordinator.runExclusivelyWhenStoreIsIdle(operationName: "test cleanup") {
                operationStarted.fulfill()
                if await Self.waitForCancellation(deadline: 5) {
                    await sawCancellation.set()
                }
                return true
            }
        }
        await fulfillment(of: [operationStarted], timeout: 2)

        maintenance.cancel()
        _ = await maintenance.value

        let cancelled = await sawCancellation.value
        XCTAssertTrue(cancelled)
        let isRunning = await syncRunCoordinator.isRunning()
        XCTAssertFalse(isRunning, "The run is ended once the cancelled operation has returned")
    }

    // Revert-check: `parkUntilIdleOrCancelled()` in
    // `SyncRunCoordinator.acquireRunWithTask`, which this goes through. A
    // caller cancelled while it waits behind a sync (a background task that
    // expired) must be answered then, not when the sync ends: the sync here
    // is held past the deadline, so with the plain park the request has not
    // returned and the first assertion fails.
    func testCancellingTheCaller_whileItWaitsBehindASync_answersBeforeTheSyncEnds() async throws {
        let syncRunCoordinator = SyncRunCoordinator()
        let coordinator = StoreMaintenanceCoordinator(syncRunCoordinator: syncRunCoordinator)
        let operationRan = AsyncFlag()
        let answered = AsyncFlag()
        let beganSync = await syncRunCoordinator.beginRun(kind: .foregroundIncremental)
        let activeSync = try XCTUnwrap(beganSync)

        let maintenance = Task { () -> Bool in
            let succeeded = await coordinator.runExclusivelyWhenStoreIsIdle(operationName: "test cleanup") {
                await operationRan.set()
                return true
            }
            await answered.set()
            return succeeded
        }
        let parked = AsyncFlag()
        Task {
            await syncRunCoordinator.waitUntilWorkIsWaiting()
            await parked.set()
        }
        let waited = await Self.waitUntil(timeout: 5) { await parked.value }
        XCTAssertTrue(waited, "The maintenance waits for the sync's run to end")

        maintenance.cancel()
        let answeredWhileTheSyncRan = await Self.waitUntil(timeout: 5) { await answered.value }
        XCTAssertTrue(
            answeredWhileTheSyncRan,
            "A cancelled request must not wait for the sync ahead of it to end"
        )

        await syncRunCoordinator.endRun(activeSync)
        let succeeded = await maintenance.value
        XCTAssertFalse(succeeded)
        let didRunOperation = await operationRan.value
        XCTAssertFalse(didRunOperation, "Nothing runs for a cancelled request")

        // The coordinator is free again: a later request is not refused as
        // "already running", and takes the run.
        let later = await coordinator.runExclusivelyWhenStoreIsIdle(operationName: "later cleanup") { true }
        XCTAssertTrue(later)
    }

    nonisolated private static func waitUntil(
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

    // Revert-check: the nil `StoreMaintenanceCoordinator.resultOfExclusiveRun`
    // returns for an operation that never ran, as distinct from what an
    // operation that ran returned. `DataCleanupService.runStoreMaintenanceIfDue`
    // reads the nil as `.notAdmitted`.
    func testResultOfExclusiveRun_returnsTheOperationsValue_andNilWhenNotAdmitted() async {
        let syncRunCoordinator = SyncRunCoordinator()
        let coordinator = StoreMaintenanceCoordinator(syncRunCoordinator: syncRunCoordinator)

        let ran = await coordinator.resultOfExclusiveRun(operationName: "test cleanup") { "ran" }
        XCTAssertEqual(ran, "ran")

        await syncRunCoordinator.beginQuiescence()
        let refused = await coordinator.resultOfExclusiveRun(operationName: "test cleanup") { "ran" }
        await syncRunCoordinator.endQuiescence()
        XCTAssertNil(refused, "An account transition admits nothing")
    }

    /// Stands in for a maintenance operation's work: returns true as soon as
    /// its task is cancelled, false if `deadline` seconds pass first.
    nonisolated private static func waitForCancellation(deadline: TimeInterval) async -> Bool {
        let end = Date().addingTimeInterval(deadline)
        while Date() < end {
            if Task.isCancelled { return true }
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        return Task.isCancelled
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
    private(set) var value = false

    func set() {
        value = true
    }
}
