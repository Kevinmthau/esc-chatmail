import XCTest
import CoreData
@testable import esc_chatmail

/// Pins the production store's asynchronous add: `waitForStoreToLoad` is
/// answered by the load itself, by its own timeout or by cancellation, and
/// fresh-install cleanup removes a store that has not been loaded without
/// loading it.
final class CoreDataStackAsyncLoadTests: XCTestCase {
    private var directoriesToRemove: [URL] = []

    override func tearDown() {
        for directory in directoriesToRemove {
            try? FileManager.default.removeItem(at: directory)
        }
        directoriesToRemove = []
        super.tearDown()
    }

    // MARK: - waitForStoreToLoad

    /// Revert-check: removing the waiter resumption from
    /// `CoreDataStack.setStoreLoaded` leaves the waiter to time out.
    func testWaitForStoreToLoad_asyncAddedStore_resumesWaiterRegisteredBeforeTheLoad() async throws {
        let container = TestCoreDataStack.makeUnloadedSQLiteContainer(
            storeURL: try makeStoreURL(),
            addsStoreAsynchronously: true
        )
        let stack = CoreDataStack(unloadedPersistentContainerForTesting: container)
        let waiter = Task { try await stack.waitForStoreToLoad(timeout: 10) }
        await waitUntil { stack.debugPendingLoadWaiterCount == 1 }

        _ = stack.persistentContainer
        try await waiter.value

        XCTAssertTrue(stack.isStoreLoaded)
        XCTAssertFalse(stack.isStoreLoadInFlight, "The attached store must end the load's claim")
        XCTAssertEqual(container.persistentStoreCoordinator.persistentStores.count, 1)
        XCTAssertEqual(stack.debugPendingLoadWaiterCount, 0)
    }

    /// Revert-check: dropping the timer from
    /// `CoreDataStack.registerLoadWaiter` leaves the waiter waiting forever.
    func testWaitForStoreToLoad_noLoadStarted_throwsAtItsTimeoutAndForgetsTheWaiter() async throws {
        let stack = CoreDataStack(
            unloadedPersistentContainerForTesting: TestCoreDataStack.makeUnloadedSQLiteContainer(
                storeURL: try makeStoreURL()
            )
        )

        do {
            try await stack.waitForStoreToLoad(timeout: 0.05)
            XCTFail("Expected the wait to time out")
        } catch CoreDataError.storeLoadFailed {
        }
        XCTAssertEqual(stack.debugPendingLoadWaiterCount, 0)
    }

    /// Revert-check: removing the `onCancel` handler from
    /// `CoreDataStack.waitForStoreToLoad` leaves the cancelled waiter waiting.
    func testWaitForStoreToLoad_cancelledWhileWaiting_throwsCancellationError() async throws {
        let stack = CoreDataStack(
            unloadedPersistentContainerForTesting: TestCoreDataStack.makeUnloadedSQLiteContainer(
                storeURL: try makeStoreURL()
            )
        )
        let waiter = Task { try await stack.waitForStoreToLoad(timeout: .infinity) }
        await waitUntil { stack.debugPendingLoadWaiterCount == 1 }

        waiter.cancel()

        do {
            try await waiter.value
            XCTFail("Expected the cancelled wait to throw")
        } catch is CancellationError {
        }
        XCTAssertEqual(stack.debugPendingLoadWaiterCount, 0)
    }

    /// A task cancelled before it waits runs the cancellation handler before
    /// the waiter exists, so only the re-check after registering answers it.
    ///
    /// Revert-check: dropping the `Task.isCancelled` check from
    /// `CoreDataStack.registerLoadWaiter` leaves the waiter waiting.
    func testWaitForStoreToLoad_cancelledBeforeWaiting_throwsCancellationError() async throws {
        let stack = CoreDataStack(
            unloadedPersistentContainerForTesting: TestCoreDataStack.makeUnloadedSQLiteContainer(
                storeURL: try makeStoreURL()
            )
        )
        let (gate, openGate) = AsyncStream<Void>.makeStream()
        let waiter = Task {
            for await _ in gate { break }
            try await stack.waitForStoreToLoad(timeout: .infinity)
        }

        waiter.cancel()
        openGate.finish()

        do {
            try await waiter.value
            XCTFail("Expected the cancelled wait to throw")
        } catch is CancellationError {
        }
        XCTAssertEqual(stack.debugPendingLoadWaiterCount, 0)
    }

    /// Revert-check: returning a deadline for a timeout that is not finite
    /// from `CoreDataStack.loadWaitDeadline` fails the first two assertions.
    func testLoadWaitDeadline_boundsTheTimeout() {
        let now = DispatchTime(uptimeNanoseconds: 1_000)
        let year = 365 * 24 * 60 * 60

        XCTAssertNil(CoreDataStack.loadWaitDeadline(after: .infinity, now: now))
        XCTAssertNil(CoreDataStack.loadWaitDeadline(after: .nan, now: now))
        XCTAssertEqual(CoreDataStack.loadWaitDeadline(after: -5, now: now), now + .nanoseconds(0))
        XCTAssertEqual(CoreDataStack.loadWaitDeadline(after: 2, now: now), now + .seconds(2))
        XCTAssertEqual(CoreDataStack.loadWaitDeadline(after: 1e12, now: now), now + .seconds(year))
    }

    // MARK: - Fresh install

    /// Revert-check: making `CoreDataStack.removeStoreForFreshInstall` call
    /// `destroyAndReloadAsync()` whatever the container's state loads the
    /// store, which fails the `isStoreLoaded` assertion.
    func testRemoveStoreForFreshInstall_containerNotCreated_removesStoreWithoutLoadingIt() async throws {
        let storeURL = try makeStoreURL()
        try seedStore(at: storeURL, labelCount: 1)
        let backup = try CoreDataBackupManager.createTimestampedBackup(at: storeURL)
        let container = TestCoreDataStack.makeUnloadedSQLiteContainer(
            storeURL: storeURL,
            addsStoreAsynchronously: true
        )
        let stack = CoreDataStack(unloadedPersistentContainerForTesting: container)

        try await stack.removeStoreForFreshInstall()

        XCTAssertFalse(stack.isStoreLoaded, "The store must be removed, never loaded")
        XCTAssertFalse(stack.isStoreLoadInFlight)
        XCTAssertTrue(container.persistentStoreCoordinator.persistentStores.isEmpty)
        for suffix in ["", "-wal", "-shm"] {
            XCTAssertFalse(FileManager.default.fileExists(atPath: storeURL.path + suffix), "store\(suffix) left behind")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: backup.path))

        _ = stack.persistentContainer
        try await stack.waitForStoreToLoad(timeout: 10)
        let labelCount = try await countLabels(in: container)
        XCTAssertEqual(labelCount, 0, "The launch's load must open an empty store")
    }

    /// Once the container exists its store may be attached, so it is
    /// destroyed and reloaded, never removed by path from under it.
    ///
    /// Revert-check: dropping the `_isContainerCreated` check from
    /// `CoreDataStack.storeURLIfContainerNotCreated` removes the files of the
    /// open store, which fails the reload.
    func testRemoveStoreForFreshInstall_containerCreated_reloadsAnEmptyStore() async throws {
        let container = TestCoreDataStack.makeUnloadedSQLiteContainer(
            storeURL: try makeStoreURL(),
            addsStoreAsynchronously: true
        )
        let stack = CoreDataStack(unloadedPersistentContainerForTesting: container)
        _ = stack.persistentContainer
        try await stack.waitForStoreToLoad(timeout: 10)
        try insertLabel(into: container)

        try await stack.removeStoreForFreshInstall()

        XCTAssertTrue(stack.isStoreLoaded)
        XCTAssertEqual(container.persistentStoreCoordinator.persistentStores.count, 1)
        let labelCount = try await countLabels(in: container)
        XCTAssertEqual(labelCount, 0)
    }

    /// Fresh-install cleanup removes the production store by this URL without
    /// creating the container, so it must be the one the container opens.
    ///
    /// Revert-check: changing the path extension in
    /// `CoreDataStack.defaultStoreURL` fails the assertion.
    func testDefaultStoreURL_isTheAppContainersDefault() throws {
        XCTAssertEqual(CoreDataStack.defaultStoreURL, try XCTUnwrap(TestCoreDataStack.defaultAppStoreURL()))
    }

    // MARK: - Helpers

    private func makeStoreURL() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TestCoreDataStack-AsyncLoad-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        directoriesToRemove.append(directory)
        return directory.appendingPathComponent("Mailbox.sqlite")
    }

    private func seedStore(at storeURL: URL, labelCount: Int) throws {
        let seedContainer = TestCoreDataStack.makeUnloadedSQLiteContainer(storeURL: storeURL)
        var loadError: Error?
        seedContainer.loadPersistentStores { _, error in loadError = error }
        if let loadError { throw loadError }
        for _ in 0..<labelCount {
            try insertLabel(into: seedContainer)
        }
        for store in seedContainer.persistentStoreCoordinator.persistentStores {
            try seedContainer.persistentStoreCoordinator.remove(store)
        }
    }

    private func insertLabel(into container: NSPersistentContainer) throws {
        let context = container.newBackgroundContext()
        try context.performAndWait {
            let label = NSEntityDescription.insertNewObject(forEntityName: "Label", into: context)
            label.setValue(UUID().uuidString, forKey: "id")
            label.setValue("Label", forKey: "name")
            try context.save()
        }
    }

    private func countLabels(in container: NSPersistentContainer) async throws -> Int {
        let context = container.newBackgroundContext()
        return try await context.perform {
            try context.count(for: NSFetchRequest<NSManagedObject>(entityName: "Label"))
        }
    }

    private func waitUntil(
        timeout: TimeInterval = 5.0,
        pollIntervalNanoseconds: UInt64 = 10_000_000,
        file: StaticString = #filePath,
        line: UInt = #line,
        condition: @escaping () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else {
                XCTFail("Timed out waiting for condition", file: file, line: line)
                return
            }
            try? await Task.sleep(nanoseconds: pollIntervalNanoseconds)
        }
    }
}
