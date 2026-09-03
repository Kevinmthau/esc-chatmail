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
