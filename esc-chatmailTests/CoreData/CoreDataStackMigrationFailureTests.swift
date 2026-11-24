import XCTest
import CoreData
import SQLite3
@testable import esc_chatmail

/// A migration-family load error keeps the store, in every launch: it used to back the
/// store up and delete it on the first failure, so a downgraded build (an older TestFlight
/// build, a development build sharing the Mac's container) or a migration that failed on
/// the user's data emptied the mailbox with no word. Kevin, 2026-11-24: a store a newer
/// build saved is never reset; one whose migration failed may be, by the user, behind the
/// confirmation.
///
/// The stores are real SQLite files on the process-wide model. A newer build's store is
/// this model's store with one entity hash added to its metadata, and a failed migration is
/// this model's store stamped with version 5's hashes, so that Core Data runs the inferred
/// migration from version 5 over tables that already have version 6's columns. Neither needs
/// a second live model.
final class CoreDataStackMigrationFailureTests: XCTestCase {
    private static let plentyOfSpace: Int64 = 50 * 1024 * 1024 * 1024
    private var directoriesToRemove: [URL] = []

    override func tearDown() {
        for directory in directoriesToRemove {
            try? FileManager.default.removeItem(at: directory)
        }
        directoriesToRemove = []
        super.tearDown()
    }

    // Revert-check: the `.migrationFailed` case of `CoreDataStack.handleStoreLoadError`.
    // Sent back to `attemptStoreReset` (the old migration recovery: back up, remove,
    // reload), the load succeeds on an empty store, the rows are gone and a backup exists.
    func testLoad_storeFromNewerModel_keepsStoreAndLatchesStoreFromNewerVersion() async throws {
        let storeURL = try makeStore(labelCount: 2)
        try stampMetadata(ofStoreAt: storeURL) { hashes in
            hashes["EntityFromANewerBuild"] = Data(repeating: 7, count: 32)
        }
        let marker = MarkerProbe()
        let stack = makeStack(storeURL: storeURL, marker: marker)
        _ = stack.persistentContainer

        let latched = try await latchedLoadError(of: stack)

        guard case .storeFromNewerVersion = latched else {
            return XCTFail("Expected storeFromNewerVersion, got \(latched)")
        }
        XCTAssertEqual(storedLabelCount(inSQLiteFileAt: storeURL), 2, "The rows must stay where they were")
        XCTAssertTrue(CoreDataBackupManager.listBackups(for: storeURL).isEmpty, "Nothing was backed up, so nothing was removed")
        XCTAssertEqual(marker.count, 0)
    }

    // Revert-check: `CoreDataStack.allowsResetAfterLoadFailure` accepting
    // `.storeFromNewerVersion`. A newer build's store is then removed.
    func testResetStoreAfterLoadFailure_storeFromNewerModel_isRefusedAndKeepsStore() async throws {
        let storeURL = try makeStore(labelCount: 1)
        try stampMetadata(ofStoreAt: storeURL) { hashes in
            hashes["EntityFromANewerBuild"] = Data(repeating: 7, count: 32)
        }
        let marker = MarkerProbe()
        let stack = makeStack(storeURL: storeURL, marker: marker)
        _ = stack.persistentContainer
        _ = try await latchedLoadError(of: stack)

        XCTAssertEqual(stack.resetStoreAfterLoadFailure(), .notResettable)

        XCTAssertEqual(storedLabelCount(inSQLiteFileAt: storeURL), 1)
        XCTAssertEqual(marker.count, 0)
    }

    // Revert-check: the `.bundledVersion` branch of
    // `StoreModelCompatibility.loadError(forMigrationFailure:…)` (answer
    // `.storeFromNewerVersion` there and the user can never reset a store whose
    // migration failed), and the `.migrationFailed` case of
    // `CoreDataStack.handleStoreLoadError` (the store is then deleted on the spot).
    func testLoad_migrationFromBundledVersionFails_keepsStoreAndLatchesMigrationFailed() async throws {
        let storeURL = try makeStore(labelCount: 3)
        try stampWithBundledVersion("ESCChatmail 5", storeAt: storeURL)
        let marker = MarkerProbe()
        let stack = makeStack(storeURL: storeURL, marker: marker)
        _ = stack.persistentContainer

        let latched = try await latchedLoadError(of: stack)

        guard case .migrationFailed = latched else {
            return XCTFail("Expected migrationFailed, got \(latched)")
        }
        XCTAssertEqual(storedLabelCount(inSQLiteFileAt: storeURL), 3)
        XCTAssertTrue(CoreDataBackupManager.listBackups(for: storeURL).isEmpty)
        XCTAssertEqual(marker.count, 0, "Nothing may mark a reset that did not happen")
    }

    /// The way out Kevin chose for a failed migration: the confirmed reset removes the store
    /// that never attached, by path, with its sidecars, and the next load opens an empty one.
    ///
    /// Revert-check: `CoreDataStack.allowsResetAfterLoadFailure` accepting only
    /// `.unavailable` (the reset is then refused and the load fails again), and the
    /// `markStoreRemovedByRecovery()` call in `resetStoreAfterLoadFailure`.
    func testResetStoreAfterLoadFailure_migrationFailed_removesStoreAndSidecarsThenLoadsEmpty() async throws {
        let storeURL = try makeStore(labelCount: 3)
        try stampWithBundledVersion("ESCChatmail 5", storeAt: storeURL)
        let marker = MarkerProbe()
        let stack = makeStack(storeURL: storeURL, marker: marker)
        let container = stack.persistentContainer
        _ = try await latchedLoadError(of: stack)
        // Sidecars a reader of the old file could have left. Left in place, a WAL that is
        // not the new file's makes its first open fail.
        try Data("not this file's log".utf8).write(to: URL(fileURLWithPath: storeURL.path + "-wal"))
        try Data("not this file's index".utf8).write(to: URL(fileURLWithPath: storeURL.path + "-shm"))

        XCTAssertEqual(stack.resetStoreAfterLoadFailure(), .removed)
        XCTAssertEqual(marker.count, 1, "The restore that follows must know the store was reset by recovery")
        XCTAssertFalse(FileManager.default.fileExists(atPath: storeURL.path + "-wal"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: storeURL.path + "-shm"))
        stack.retryLoadAfterFailure()

        try await stack.waitForStoreToLoad(timeout: 5)
        XCTAssertEqual(container.persistentStoreCoordinator.persistentStores.count, 1)
        let labelCount = try await countLabels(in: container)
        XCTAssertEqual(labelCount, 0)
        XCTAssertEqual(CoreDataBackupManager.listBackups(for: storeURL).count, 1, "The reset keeps its backup")
    }

    /// The load ladder's own reset, of a file proven not to be a database, marks the reset
    /// as a recovery so that the restore after it keeps the mailbox start and the backup.
    ///
    /// Revert-check: the `markStoreRemovedByRecovery()` call in
    /// `CoreDataStack.attemptStoreReset`.
    func testLoad_corruptStore_isResetAndMarkedAsARecoveryReset() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CoreDataStackMigrationFailureTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        directoriesToRemove.append(directory)
        let storeURL = directory.appendingPathComponent("Mailbox.sqlite")
        try Data(repeating: 0x5A, count: 8_192).write(to: storeURL)
        let marker = MarkerProbe()
        let stack = makeStack(storeURL: storeURL, marker: marker)
        _ = stack.persistentContainer

        try await stack.waitForStoreToLoad(timeout: 5)

        XCTAssertEqual(marker.count, 1)
        XCTAssertEqual(CoreDataBackupManager.listBackups(for: storeURL).count, 1)
    }

    // MARK: - Helpers

    private func makeStack(storeURL: URL, marker: MarkerProbe) -> CoreDataStack {
        CoreDataStack(
            unloadedPersistentContainerForTesting: TestCoreDataStack.makeUnloadedSQLiteContainer(storeURL: storeURL),
            availableStorageBytes: { Self.plentyOfSpace },
            markStoreRemovedByRecovery: { marker.record() }
        )
    }

    private func latchedLoadError(
        of stack: CoreDataStack,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws -> PersistentStoreLoadError {
        do {
            try await stack.waitForStoreToLoad(timeout: 5)
        } catch CoreDataError.storeLoadFailed(let underlying as PersistentStoreLoadError) {
            return underlying
        }
        XCTFail("Expected the load to fail and be latched", file: file, line: line)
        throw CancellationError()
    }

    /// A store on this build's model holding `labelCount` labels, written with a rollback
    /// journal so that its rows are in the database file itself.
    private func makeStore(labelCount: Int) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CoreDataStackMigrationFailureTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        directoriesToRemove.append(directory)
        let storeURL = directory.appendingPathComponent("Mailbox.sqlite")
        let seed = TestCoreDataStack.makeUnloadedSQLiteContainer(storeURL: storeURL)
        seed.persistentStoreDescriptions[0].setOption(Self.rollbackJournal, forKey: NSSQLitePragmasOption)
        var loadError: Error?
        seed.loadPersistentStores { _, error in loadError = error }
        if let loadError { throw loadError }
        let context = seed.newBackgroundContext()
        try context.performAndWait {
            for index in 0..<labelCount {
                let label = NSEntityDescription.insertNewObject(forEntityName: "Label", into: context)
                label.setValue("label-\(index)", forKey: "id")
                label.setValue("Label \(index)", forKey: "name")
            }
            try context.save()
        }
        for store in seed.persistentStoreCoordinator.persistentStores {
            try seed.persistentStoreCoordinator.remove(store)
        }
        XCTAssertEqual(storedLabelCount(inSQLiteFileAt: storeURL), labelCount)
        return storeURL
    }

    private static let rollbackJournal = ["journal_mode": "DELETE"] as NSDictionary

    private func stampMetadata(ofStoreAt storeURL: URL, change: (inout [String: Data]) -> Void) throws {
        let options: [AnyHashable: Any] = [NSSQLitePragmasOption: Self.rollbackJournal]
        var metadata = try NSPersistentStoreCoordinator.metadataForPersistentStore(
            ofType: NSSQLiteStoreType,
            at: storeURL,
            options: options
        )
        var hashes = try XCTUnwrap(metadata[NSStoreModelVersionHashesKey] as? [String: Data])
        change(&hashes)
        metadata[NSStoreModelVersionHashesKey] = hashes
        try NSPersistentStoreCoordinator.setMetadata(
            metadata,
            forPersistentStoreOfType: NSSQLiteStoreType,
            at: storeURL,
            options: options
        )
    }

    private func stampWithBundledVersion(_ versionName: String, storeAt storeURL: URL) throws {
        let versions = try XCTUnwrap(StoreModelCompatibility.bundledVersionHashes())
        let hashes = try XCTUnwrap(versions[versionName], "\(versionName) must be bundled")
        try stampMetadata(ofStoreAt: storeURL) { $0 = hashes }
    }

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

    private func countLabels(in container: NSPersistentContainer) async throws -> Int {
        let context = container.newBackgroundContext()
        return try await context.perform {
            try context.count(for: NSFetchRequest<NSManagedObject>(entityName: "Label"))
        }
    }
}

/// Counts the stack's calls to mark a recovery reset.
private final class MarkerProbe: @unchecked Sendable {
    /// `@unchecked Sendable`: `lock` guards `calls`.
    private let lock = NSLock()
    private var calls = 0

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return calls
    }

    func record() {
        lock.lock()
        calls += 1
        lock.unlock()
    }
}
