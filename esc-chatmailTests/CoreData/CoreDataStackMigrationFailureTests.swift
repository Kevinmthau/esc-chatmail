import XCTest
import CoreData
import SQLite3
@testable import esc_chatmail

/// A migration-family load error keeps the store, in every launch: it used to back the
/// store up and delete it on the first failure, so a downgraded build (an older TestFlight
/// build, a development build sharing the Mac's container) or a migration that failed on
/// the user's data emptied the mailbox with no word. Kevin, 2026-11-24: either may be reset
/// by the user, behind the confirmation, and never by the app.
///
/// The stores are real SQLite files on the process-wide model. A newer build's store is
/// this model's store with one entity hash added to its metadata and a model ordinal above
/// this build's stamped in it, and a failed migration is this model's store stamped with
/// version 5's hashes, so that Core Data runs the inferred migration from version 5 over
/// tables that already have version 6's columns. The tests load no model of their own;
/// Core Data's own search for a migration's source model reads the bundled ones.
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
        try stampAsWrittenByANewerBuild(storeAt: storeURL)
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

    /// Kevin, 2026-11-24: a newer build's store is reset as any other is, once the user
    /// confirms: the reset removes it by path and the next load opens an empty store.
    ///
    /// Revert-check: `CoreDataStack.allowsResetAfterLoadFailure` refusing
    /// `.storeFromNewerVersion` (the reset is then refused and the store stays).
    func testResetStoreAfterLoadFailure_storeFromNewerModel_removesStoreOnceConfirmed() async throws {
        let storeURL = try makeStore(labelCount: 1)
        try stampAsWrittenByANewerBuild(storeAt: storeURL)
        let marker = MarkerProbe()
        let stack = makeStack(storeURL: storeURL, marker: marker)
        let container = stack.persistentContainer
        _ = try await latchedLoadError(of: stack)

        XCTAssertEqual(stack.resetStoreAfterLoadFailure(), .removed)
        stack.retryLoadAfterFailure()

        try await stack.waitForStoreToLoad(timeout: 5)
        let labelCount = try await countLabels(in: container)
        XCTAssertEqual(labelCount, 0)
        XCTAssertEqual(marker.count, 1)
        XCTAssertEqual(CoreDataBackupManager.listBackups(for: storeURL).count, 1, "The reset keeps its backup")
    }

    // Revert-check: the `.notNewer` branch of
    // `StoreModelCompatibility.loadError(forMigrationFailure:…)` (answer
    // `.storeFromNewerVersion` there and a failed migration is told to update to a
    // build that does not exist), and the `.migrationFailed` case of
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

    /// A store whose hashes match no model this build bundles and that no build stamped:
    /// what a build of the first model wrote before that model was edited in place, or a
    /// development build's model that changed again before it shipped. Without the stamp
    /// nothing proves a newer build wrote it, so it is a failed migration, not a newer
    /// build's store, whose notice asks for an update that does not exist.
    ///
    /// Revert-check: deciding "newer" from the hashes again (a store matching no bundled
    /// version answered `.storeFromNewerVersion`).
    func testLoad_unknownModelWithNoStamp_isAResettableMigrationFailure() async throws {
        let storeURL = try makeStore(labelCount: 1)
        try stampMetadata(ofStoreAt: storeURL) { hashes in
            hashes["EntityOfAnEditedFirstModel"] = Data(repeating: 3, count: 32)
        }
        let stack = makeStack(storeURL: storeURL, marker: MarkerProbe())
        _ = stack.persistentContainer

        let latched = try await latchedLoadError(of: stack)

        guard case .migrationFailed = latched else {
            return XCTFail("Expected migrationFailed, got \(latched)")
        }
        XCTAssertEqual(storedLabelCount(inSQLiteFileAt: storeURL), 1)
    }

    /// A successful load stamps this build's model in the store, and the next save writes
    /// it: that stamp is what an older build reads as "a newer build saved this".
    ///
    /// Revert-check: the `stampCurrentModelOrdinal` call in
    /// `CoreDataStack.loadPersistentStores`.
    func testLoad_success_stampsThisBuildsModelOrdinalWithTheNextSave() async throws {
        let storeURL = try makeStore(labelCount: 0)
        let stack = makeStack(storeURL: storeURL, marker: MarkerProbe())
        let container = stack.persistentContainer
        try await stack.waitForStoreToLoad(timeout: 5)
        let context = container.newBackgroundContext()
        try await context.perform {
            let label = NSEntityDescription.insertNewObject(forEntityName: "Label", into: context)
            label.setValue("label-after-load", forKey: "id")
            label.setValue("After load", forKey: "name")
            try context.save()
        }
        for store in container.persistentStoreCoordinator.persistentStores {
            try container.persistentStoreCoordinator.remove(store)
        }

        let metadata = try NSPersistentStoreCoordinator.metadataForPersistentStore(
            ofType: NSSQLiteStoreType,
            at: storeURL,
            options: nil
        )

        XCTAssertEqual(
            (metadata[StoreModelCompatibility.modelOrdinalMetadataKey] as? NSNumber)?.intValue,
            try XCTUnwrap(StoreModelCompatibility.currentModelOrdinal())
        )
    }

    /// A failed migration is not run again by the launch loop's timed retries or a
    /// background task: each reload runs the migration on the main actor before it fails
    /// the same way. The user's Try Again or Reset Mailbox permits one reload.
    ///
    /// Revert-check: the `isDeterministicLoadFailure` gate in
    /// `CoreDataStack.retryLoadAfterFailure` (the first retry then reloads the store this
    /// test has made openable).
    func testRetryLoadAfterFailure_failedMigration_reloadsOnlyWhenPermitted() async throws {
        let storeURL = try makeStore(labelCount: 2)
        let ownHashes = TestCoreDataStack.sharedModelVersionHashes
        try stampWithBundledVersion("ESCChatmail 5", storeAt: storeURL)
        let stack = makeStack(storeURL: storeURL, marker: MarkerProbe())
        let container = stack.persistentContainer
        _ = try await latchedLoadError(of: stack)
        // What a reload would now find: a store this build opens.
        try stampMetadata(ofStoreAt: storeURL) { $0 = ownHashes }

        stack.retryLoadAfterFailure()
        let stillLatched = try await latchedLoadError(of: stack)
        guard case .migrationFailed = stillLatched else {
            return XCTFail("Expected the latch to stay, got \(stillLatched)")
        }
        XCTAssertTrue(container.persistentStoreCoordinator.persistentStores.isEmpty)

        stack.permitReloadAfterDeterministicFailure()
        stack.retryLoadAfterFailure()
        try await stack.waitForStoreToLoad(timeout: 5)
        let labelCount = try await countLabels(in: container)
        XCTAssertEqual(labelCount, 2)
    }

    /// The way out Kevin chose for a failed migration: the confirmed reset removes the store
    /// that never attached, by path, with its sidecars, and the next load opens an empty one.
    ///
    /// Revert-check: `CoreDataStack.allowsResetAfterLoadFailure` accepting only
    /// `.unavailable` (the reset is then refused and the load fails again), the
    /// `markStoreRemovedByRecovery()` call in `resetStoreAfterLoadFailure`, and its
    /// `permitReloadAfterDeterministicFailure()` (the retry then leaves the latch).
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

    private func stampMetadata(
        ofStoreAt storeURL: URL,
        extraMetadata: [String: Any] = [:],
        change: (inout [String: Data]) -> Void
    ) throws {
        let options: [AnyHashable: Any] = [NSSQLitePragmasOption: Self.rollbackJournal]
        var metadata = try NSPersistentStoreCoordinator.metadataForPersistentStore(
            ofType: NSSQLiteStoreType,
            at: storeURL,
            options: options
        )
        var hashes = try XCTUnwrap(metadata[NSStoreModelVersionHashesKey] as? [String: Data])
        change(&hashes)
        metadata[NSStoreModelVersionHashesKey] = hashes
        metadata.merge(extraMetadata) { _, new in new }
        try NSPersistentStoreCoordinator.setMetadata(
            metadata,
            forPersistentStoreOfType: NSSQLiteStoreType,
            at: storeURL,
            options: options
        )
    }

    private func stampWithBundledVersion(_ versionName: String, storeAt storeURL: URL) throws {
        let versions = try XCTUnwrap(Self.bundledVersionHashes())
        let hashes = try XCTUnwrap(versions[versionName], "\(versionName) must be bundled")
        try stampMetadata(ofStoreAt: storeURL) { $0 = hashes }
    }

    /// A newer build's store: an entity this build lacks, and that build's stamp.
    private func stampAsWrittenByANewerBuild(storeAt storeURL: URL) throws {
        let ownOrdinal = try XCTUnwrap(StoreModelCompatibility.currentModelOrdinal())
        try stampMetadata(ofStoreAt: storeURL, extraMetadata: [StoreModelCompatibility.modelOrdinalMetadataKey: ownOrdinal + 1]) { hashes in
            hashes["EntityFromANewerBuild"] = Data(repeating: 7, count: 32)
        }
    }

    /// Each bundled model version's entity hashes, from the compiled model's
    /// `VersionInfo.plist`, without loading a model.
    private static func bundledVersionHashes() -> [String: [String: Data]]? {
        guard let modelURL = Bundle.main.url(forResource: "ESCChatmail", withExtension: "momd"),
              let data = try? Data(contentsOf: modelURL.appendingPathComponent("VersionInfo.plist")),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            return nil
        }
        return plist["NSManagedObjectModel_VersionHashes"] as? [String: [String: Data]]
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
