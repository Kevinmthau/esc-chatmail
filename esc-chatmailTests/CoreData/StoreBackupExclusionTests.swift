import XCTest
import CoreData
@testable import esc_chatmail

/// The mail store is left out of device backups (architecture review 2026-11,
/// security-privacy#5, Kevin's call 2026-11-28): its `.sqlite`, `-wal` and `-shm`, after every
/// load that attaches it, because the mark is each file's own and every reload of an emptied
/// or reset store makes the files again (`CoreDataStack.leaveStoreFilesOutOfBackups`).
final class StoreBackupExclusionTests: XCTestCase {
    private static let plentyOfSpace: Int64 = 50 * 1024 * 1024 * 1024
    private var directoriesToRemove: [URL] = []

    override func tearDown() {
        for directory in directoriesToRemove {
            try? FileManager.default.removeItem(at: directory)
        }
        directoriesToRemove = []
        super.tearDown()
    }

    // Revert-check: the `leaveStoreFilesOutOfBackups` call in
    // `CoreDataStack.startClaimedStoreLoad`. Without it none of the three files is marked.
    func testLoad_leavesTheStoreItsLogAndItsIndexOutOfBackups() async throws {
        let storeURL = try makeStoreURL()
        let stack = CoreDataStack(
            unloadedPersistentContainerForTesting: TestCoreDataStack.makeUnloadedSQLiteContainer(storeURL: storeURL)
        )

        _ = stack.persistentContainer
        try await stack.waitForStoreToLoad(timeout: 10)

        assertEveryStoreFileIsLeftOutOfBackups(storeURL)
    }

    // Revert-check: the `leaveStoreFilesOutOfBackups` call in
    // `CoreDataStack.startClaimedStoreLoad`, which an asynchronously added store's load
    // reaches as well. Without it none of the three files is marked.
    func testAsynchronouslyAddedLoad_leavesAllThreeFilesOutOfBackups() async throws {
        let storeURL = try makeStoreURL()
        let stack = CoreDataStack(
            unloadedPersistentContainerForTesting: TestCoreDataStack.makeUnloadedSQLiteContainer(
                storeURL: storeURL,
                addsStoreAsynchronously: true
            )
        )

        _ = stack.persistentContainer
        try await stack.waitForStoreToLoad(timeout: 10)

        assertEveryStoreFileIsLeftOutOfBackups(storeURL)
    }

    // Revert-check: the `leaveStoreFilesOutOfBackups` call in `CoreDataStack.loadStoresAsync`.
    // Without it the files a sign-out's or a fresh install's reload makes again are backed up.
    func testDestroyAndReload_marksTheFilesTheReloadMakesAgain() async throws {
        let storeURL = try makeStoreURL()
        let stack = CoreDataStack(
            unloadedPersistentContainerForTesting: TestCoreDataStack.makeUnloadedSQLiteContainer(storeURL: storeURL)
        )
        _ = stack.persistentContainer
        try await stack.waitForStoreToLoad(timeout: 10)
        let fileBefore = try fileNumber(of: storeURL)

        try await stack.destroyAndReloadAsync()

        XCTAssertNotEqual(try fileNumber(of: storeURL), fileBefore, "The reload must have made a new file")
        assertEveryStoreFileIsLeftOutOfBackups(storeURL)
    }

    /// The recovery ladder's reset of a store that is not a database: backed up, removed, and
    /// reloaded empty through the same load branch, which marks the new files.
    ///
    /// Revert-check: the `leaveStoreFilesOutOfBackups` call in
    /// `CoreDataStack.startClaimedStoreLoad`. Without it the reloaded store is backed up.
    func testCorruptStoreReset_marksTheStoreItReloads() async throws {
        let storeURL = try makeStoreURL()
        try Data(repeating: 0x5A, count: 8_192).write(to: storeURL)
        let fileBefore = try fileNumber(of: storeURL)
        let stack = CoreDataStack(
            unloadedPersistentContainerForTesting: TestCoreDataStack.makeUnloadedSQLiteContainer(storeURL: storeURL),
            availableStorageBytes: { Self.plentyOfSpace }
        )

        _ = stack.persistentContainer
        try await stack.waitForStoreToLoad(timeout: 10)

        XCTAssertNotEqual(try fileNumber(of: storeURL), fileBefore, "The reset must have made a new store")
        assertEveryStoreFileIsLeftOutOfBackups(storeURL)
    }

    // Revert-check: the `NSSQLiteStoreType` guard in `CoreDataStack.leaveStoreFilesOutOfBackups`.
    // Without it a file at an in-memory store's URL is marked as if it were the store.
    func testLeaveStoreFilesOutOfBackups_ofAStoreThatIsNotSQLite_marksNothing() throws {
        let storeURL = try makeStoreURL()
        try Data("not a store of ours".utf8).write(to: storeURL)
        let description = NSPersistentStoreDescription(url: storeURL)
        description.type = NSInMemoryStoreType

        CoreDataStack.leaveStoreFilesOutOfBackups(for: description)

        XCTAssertFalse(BackupExclusion.isExcluded(storeURL))
    }

    // MARK: - Helpers

    /// In the Mac plan too. On macOS below 27 the marks are under a strict `XCTExpectFailure`:
    /// CI's macOS 26 lane read a file's mark false straight after `BackupExclusion.exclude`
    /// returned true (`backup-mark-macos26`, `AttachmentFileExportTests`), so the store's marks
    /// are very likely inert there. Nothing of it has been looked at on a macOS 26 machine; the
    /// day macOS 26 keeps the mark, this fails with "no failure was recorded" and the wrapper
    /// comes off.
    private func assertEveryStoreFileIsLeftOutOfBackups(
        _ storeURL: URL,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let fileURLs = CoreDataStack.storeFileURLs(for: storeURL)
        for fileURL in fileURLs {
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: fileURL.path),
                "\(fileURL.lastPathComponent) is not there",
                file: file,
                line: line
            )
        }
        let assertMarks = {
            for fileURL in fileURLs {
                XCTAssertTrue(
                    BackupExclusion.isExcluded(fileURL),
                    "\(fileURL.lastPathComponent) is backed up",
                    file: file,
                    line: line
                )
            }
        }
        #if os(macOS)
        if #unavailable(macOS 27) {
            XCTExpectFailure("backup-mark-macos26: a file's mark reads false on macOS 26") {
                assertMarks()
            }
        } else {
            assertMarks()
        }
        #else
        assertMarks()
        #endif
    }

    /// The file's inode number, so a test can tell a file made again from the same one.
    private func fileNumber(of url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return try XCTUnwrap((attributes[.systemFileNumber] as? NSNumber)?.intValue)
    }

    private func makeStoreURL() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TestCoreDataStack-BackupExclusion-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        directoriesToRemove.append(directory)
        return directory.appendingPathComponent("Mailbox.sqlite")
    }
}
