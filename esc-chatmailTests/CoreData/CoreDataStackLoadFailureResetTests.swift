import XCTest
import CoreData
import SQLite3
@testable import esc_chatmail

/// Pins the launch screen's Reset Mailbox against real SQLite stores: a load
/// error outside the classifier's reset allow-list keeps the store, and a
/// permanent one used to leave launch on the failure screen for good.
final class CoreDataStackLoadFailureResetTests: XCTestCase {
    private var directoriesToRemove: [URL] = []

    override func tearDown() {
        for directory in directoriesToRemove {
            try? FileManager.default.removeItem(at: directory)
        }
        directoriesToRemove = []
        super.tearDown()
    }

    /// Revert-check: making `CoreDataStack.resetStoreAfterLoadFailure` return
    /// `.removed` without calling `prepareStoreReset` leaves the unopenable
    /// store in place, so the reload fails.
    func testResetStoreAfterLoadFailure_unopenableStore_reloadsEmptyStoreAndKeepsBackup() async throws {
        let storeURL = try makeStoreThatCannotBeOpened(labelCount: 1)
        let container = TestCoreDataStack.makeUnloadedSQLiteContainer(storeURL: storeURL)
        let stack = CoreDataStack(unloadedPersistentContainerForTesting: container)
        _ = stack.persistentContainer
        try await assertLoadFailedKeepingStore(stack, storeURL: storeURL)

        XCTAssertEqual(stack.resetStoreAfterLoadFailure(), .removed)
        stack.retryLoadAfterFailure()

        try await stack.waitForStoreToLoad(timeout: 5)
        XCTAssertEqual(container.persistentStoreCoordinator.persistentStores.count, 1)
        let labelCount = try await countLabels(in: container)
        XCTAssertEqual(labelCount, 0, "The reset store must start empty")
        let backups = CoreDataBackupManager.listBackups(for: storeURL)
        XCTAssertEqual(backups.count, 1)
        let backup = try XCTUnwrap(backups.first)
        // The backup copied this test's `-wal` directory along with the
        // store; without it SQLite can read the backup.
        try FileManager.default.removeItem(atPath: backup.path + "-wal")
        XCTAssertEqual(
            storedLabelCount(inSQLiteFileAt: backup),
            1,
            "The removed store's rows must survive in the backup"
        )
    }

    /// The same reset driven through the launch screen's model: five failed
    /// loads offer it, and confirming it reaches a loaded store.
    ///
    /// Revert-check: deleting `retry()` from the `.removed` case of
    /// `AppLoadingModel.resetMailbox` leaves the store unloaded.
    @MainActor
    func testResetMailbox_realFailedLoad_reachesLoadedStore() async throws {
        let storeURL = try makeStoreThatCannotBeOpened(labelCount: 1)
        let container = TestCoreDataStack.makeUnloadedSQLiteContainer(storeURL: storeURL)
        let stack = CoreDataStack(unloadedPersistentContainerForTesting: container)
        let model = AppLoadingModel(
            requestRetry: { stack.retryLoadAfterFailure() },
            resetStore: { stack.resetStoreAfterLoadFailure() },
            availableCapacityBytes: { nil },
            isProtectedDataAvailable: { true }
        )
        _ = stack.persistentContainer
        for _ in 0..<AppLoadingPolicy.mailboxResetFailureThreshold {
            stack.retryLoadAfterFailure()
            do {
                try await stack.waitForStoreToLoad(timeout: 5)
                return XCTFail("Expected the store to stay unopenable")
            } catch {
                model.showStoreLoadFailure(error)
            }
        }
        XCTAssertEqual(model.storeLoadFailure?.offersMailboxReset, true)

        model.resetMailbox()

        // The reload runs in the model's retry task, so poll rather than call
        // `waitForStoreToLoad`, which throws while the failure is latched.
        await waitUntil { stack.isStoreLoaded }
        XCTAssertNil(model.storeLoadFailure)
        XCTAssertEqual(container.persistentStoreCoordinator.persistentStores.count, 1)
    }

    /// Freeing space is the fix for a full disk and keeps the data, so the
    /// stack refuses even if a caller asks.
    ///
    /// Revert-check: dropping `case PersistentStoreLoadError.unavailable =
    /// loadError` from `CoreDataStack.resetStoreAfterLoadFailure` removes the
    /// store.
    func testResetStoreAfterLoadFailure_insufficientStorageLatched_keepsStore() async throws {
        let storeURL = try makeStoreThatCannotBeOpened(labelCount: 1)
        let stack = CoreDataStack(
            unloadedPersistentContainerForTesting: TestCoreDataStack.makeUnloadedSQLiteContainer(storeURL: storeURL)
        )
        _ = stack.persistentContainer
        try await assertLoadFailedKeepingStore(stack, storeURL: storeURL)
        stack.debugSetStoreLoadErrorForTesting(
            PersistentStoreLoadError.insufficientStorage(
                NSError(domain: NSCocoaErrorDomain, code: NSFileWriteOutOfSpaceError)
            )
        )

        XCTAssertEqual(stack.resetStoreAfterLoadFailure(), .notResettable)
        XCTAssertTrue(FileManager.default.fileExists(atPath: storeURL.path))
        XCTAssertTrue(CoreDataBackupManager.listBackups(for: storeURL).isEmpty)
    }

    /// An attached store is never removed, even with a failure latched (the
    /// latch here is forced; it guards against a load that won the race).
    ///
    /// Revert-check: dropping the `persistentStores.isEmpty` condition from
    /// `CoreDataStack.resetStoreAfterLoadFailure` removes the open store.
    func testResetStoreAfterLoadFailure_storeAttached_keepsStore() async throws {
        let storeURL = try makeStoreDirectory().appendingPathComponent("Mailbox.sqlite")
        let container = TestCoreDataStack.makeUnloadedSQLiteContainer(storeURL: storeURL)
        let stack = CoreDataStack(unloadedPersistentContainerForTesting: container)
        _ = stack.persistentContainer
        try await stack.waitForStoreToLoad(timeout: 5)
        XCTAssertEqual(stack.resetStoreAfterLoadFailure(), .notResettable, "A loaded store has nothing latched")
        stack.debugSetStoreLoadErrorForTesting(
            PersistentStoreLoadError.unavailable(NSError(domain: NSCocoaErrorDomain, code: NSFileReadUnknownError))
        )

        XCTAssertEqual(stack.resetStoreAfterLoadFailure(), .notResettable)
        XCTAssertTrue(FileManager.default.fileExists(atPath: storeURL.path))
        XCTAssertEqual(container.persistentStoreCoordinator.persistentStores.count, 1)
    }

    /// With no backup there is no reset: the failure stays latched so the
    /// screen can say nothing was deleted.
    ///
    /// Revert-check: reporting `.removed` when `prepareStoreReset` returns
    /// false in `CoreDataStack.resetStoreAfterLoadFailure` fails the outcome
    /// assertion.
    func testResetStoreAfterLoadFailure_backupCannotBeWritten_reportsFailureAndStaysLatched() async throws {
        // A regular file where the store's directory belongs fails the open
        // as `.unavailable` and leaves no store file to back up.
        let storeDirectory = try makeStoreDirectory()
        try FileManager.default.removeItem(at: storeDirectory)
        try Data("not a directory".utf8).write(to: storeDirectory)
        let stack = CoreDataStack(
            unloadedPersistentContainerForTesting: TestCoreDataStack.makeUnloadedSQLiteContainer(
                storeURL: storeDirectory.appendingPathComponent("Mailbox.sqlite")
            )
        )
        _ = stack.persistentContainer
        do {
            try await stack.waitForStoreToLoad(timeout: 5)
            return XCTFail("Expected the first load to fail")
        } catch CoreDataError.storeLoadFailed(PersistentStoreLoadError.unavailable) {
        }

        XCTAssertEqual(stack.resetStoreAfterLoadFailure(), .failed)

        do {
            try await stack.waitForStoreToLoad(timeout: 1)
            XCTFail("A failed reset must leave the load failure latched")
        } catch CoreDataError.storeLoadFailed(PersistentStoreLoadError.unavailable) {
        }
    }

    // MARK: - Helpers

    private func makeStoreDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CoreDataStackLoadFailureResetTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        directoriesToRemove.append(directory)
        return directory
    }

    /// Writes a real store holding `labelCount` labels and puts a directory
    /// where its write-ahead log belongs. The database file is intact and
    /// copyable, but the stack's WAL-mode open fails with SQLITE_CANTOPEN,
    /// which keeps the store (`.unavailable`) rather than resetting it. The
    /// seed uses a rollback journal so its rows live in the database file
    /// itself, where `storedLabelCount(inSQLiteFileAt:)` can read them.
    private func makeStoreThatCannotBeOpened(labelCount: Int) throws -> URL {
        let storeURL = try makeStoreDirectory().appendingPathComponent("Mailbox.sqlite")
        let seedContainer = TestCoreDataStack.makeUnloadedSQLiteContainer(storeURL: storeURL)
        seedContainer.persistentStoreDescriptions[0].setOption(
            ["journal_mode": "DELETE"] as NSDictionary,
            forKey: NSSQLitePragmasOption
        )
        var loadError: Error?
        seedContainer.loadPersistentStores { _, error in loadError = error }
        if let loadError { throw loadError }

        let context = seedContainer.newBackgroundContext()
        try context.performAndWait {
            for index in 0..<labelCount {
                let label = NSEntityDescription.insertNewObject(forEntityName: "Label", into: context)
                label.setValue("label-\(index)", forKey: "id")
                label.setValue("Label \(index)", forKey: "name")
            }
            try context.save()
        }
        for store in seedContainer.persistentStoreCoordinator.persistentStores {
            try seedContainer.persistentStoreCoordinator.remove(store)
        }

        XCTAssertEqual(storedLabelCount(inSQLiteFileAt: storeURL), labelCount, "Seed rows must be in the database file")
        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: storeURL.path + "-wal"),
            withIntermediateDirectories: false
        )
        return storeURL
    }

    /// Reads a store file with SQLite directly, so the backup can be checked
    /// without opening it through Core Data.
    private func storedLabelCount(inSQLiteFileAt url: URL) -> Int? {
        var database: OpaquePointer?
        defer { sqlite3_close(database) }
        guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            return nil
        }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(database, "SELECT count(*) FROM ZLABEL", -1, &statement, nil) == SQLITE_OK,
              sqlite3_step(statement) == SQLITE_ROW else {
            return nil
        }
        return Int(sqlite3_column_int(statement, 0))
    }

    private func assertLoadFailedKeepingStore(
        _ stack: CoreDataStack,
        storeURL: URL,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        do {
            try await stack.waitForStoreToLoad(timeout: 5)
            XCTFail("Expected the store to be unopenable", file: file, line: line)
        } catch CoreDataError.storeLoadFailed(PersistentStoreLoadError.unavailable) {
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: storeURL.path),
                "The failed load must keep the store",
                file: file,
                line: line
            )
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

    private func countLabels(in container: NSPersistentContainer) async throws -> Int {
        let context = container.newBackgroundContext()
        return try await context.perform {
            try context.count(for: NSFetchRequest<NSManagedObject>(entityName: "Label"))
        }
    }
}
