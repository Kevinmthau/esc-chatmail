import XCTest
@testable import esc_chatmail

final class CoreDataBackupManagerTests: XCTestCase {

    private var tempDir: URL!
    private var storeURL: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CoreDataBackupManagerTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        storeURL = tempDir.appendingPathComponent("Store.sqlite")
        try Data("main".utf8).write(to: storeURL)
    }

    override func tearDownWithError() throws {
        if FileManager.default.fileExists(atPath: tempDir.path) {
            try FileManager.default.removeItem(at: tempDir)
        }
        try super.tearDownWithError()
    }

    private func writeBackup(named filename: String, createdAt creationDate: Date? = nil) throws -> URL {
        let backupsDir = tempDir.appendingPathComponent("Backups")
        try FileManager.default.createDirectory(at: backupsDir, withIntermediateDirectories: true)

        let url = backupsDir.appendingPathComponent(filename)
        try Data().write(to: url)

        if let creationDate {
            try FileManager.default.setAttributes([.creationDate: creationDate], ofItemAtPath: url.path)
        }

        return url
    }

    // MARK: - Backup Creation

    func testCreateTimestampedBackup_copiesMainStoreFile() throws {
        let backup = try CoreDataBackupManager.createTimestampedBackup(at: storeURL)

        XCTAssertTrue(FileManager.default.fileExists(atPath: backup.path))
        XCTAssertEqual(try Data(contentsOf: backup), Data("main".utf8))
    }

    func testCreateTimestampedBackup_placesBackupInBackupsDirectory() throws {
        let backup = try CoreDataBackupManager.createTimestampedBackup(at: storeURL)
        XCTAssertEqual(backup.deletingLastPathComponent().lastPathComponent, "Backups")
    }

    func testCreateTimestampedBackup_includesTimestampInFilename() throws {
        let backup = try CoreDataBackupManager.createTimestampedBackup(at: storeURL)
        XCTAssertTrue(backup.lastPathComponent.contains("backup-"))
        XCTAssertEqual(backup.pathExtension, "sqlite")
    }

    func testCreateTimestampedBackup_copiesAssociatedWALAndSHM() throws {
        let walURL = URL(fileURLWithPath: storeURL.path + "-wal")
        let shmURL = URL(fileURLWithPath: storeURL.path + "-shm")
        try Data("wal".utf8).write(to: walURL)
        try Data("shm".utf8).write(to: shmURL)

        let backup = try CoreDataBackupManager.createTimestampedBackup(at: storeURL)
        let backupWal = URL(fileURLWithPath: backup.path + "-wal")
        let backupShm = URL(fileURLWithPath: backup.path + "-shm")

        XCTAssertTrue(FileManager.default.fileExists(atPath: backupWal.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: backupShm.path))
        XCTAssertEqual(try Data(contentsOf: backupWal), Data("wal".utf8))
        XCTAssertEqual(try Data(contentsOf: backupShm), Data("shm".utf8))
    }

    func testCreateTimestampedBackup_missingSourceFile_throws() {
        let missing = tempDir.appendingPathComponent("does-not-exist.sqlite")
        XCTAssertThrowsError(try CoreDataBackupManager.createTimestampedBackup(at: missing))
    }

    // MARK: - Remove Store

    func testRemoveStore_removesMainAndJournalFiles() throws {
        let walURL = URL(fileURLWithPath: storeURL.path + "-wal")
        let shmURL = URL(fileURLWithPath: storeURL.path + "-shm")
        try Data("wal".utf8).write(to: walURL)
        try Data("shm".utf8).write(to: shmURL)

        try CoreDataBackupManager.removeStore(at: storeURL)

        XCTAssertFalse(FileManager.default.fileExists(atPath: storeURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: walURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: shmURL.path))
    }

    func testRemoveStore_missingMainFile_throws() {
        let missing = tempDir.appendingPathComponent("does-not-exist.sqlite")
        XCTAssertThrowsError(try CoreDataBackupManager.removeStore(at: missing))
    }

    func testRemoveStore_missingJournalFiles_doesNotThrow() throws {
        // Only main file present; journal files are best-effort cleanup
        try CoreDataBackupManager.removeStore(at: storeURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: storeURL.path))
    }

    // MARK: - List Backups

    func testListBackups_emptyDirectory_returnsEmpty() {
        let backups = CoreDataBackupManager.listBackups(for: storeURL)
        XCTAssertEqual(backups, [])
    }

    func testListBackups_returnsOnlySqliteFiles() throws {
        let backupsDir = tempDir.appendingPathComponent("Backups")
        try FileManager.default.createDirectory(at: backupsDir, withIntermediateDirectories: true)
        try Data().write(to: backupsDir.appendingPathComponent("a.sqlite"))
        try Data().write(to: backupsDir.appendingPathComponent("b.sqlite"))
        try Data().write(to: backupsDir.appendingPathComponent("ignore.txt"))

        let backups = CoreDataBackupManager.listBackups(for: storeURL)
        XCTAssertEqual(backups.count, 2)
        XCTAssertTrue(backups.allSatisfy { $0.pathExtension == "sqlite" })
    }

    func testListBackups_sortsNewestFirst() throws {
        let first = try CoreDataBackupManager.createTimestampedBackup(at: storeURL)
        // Sleep just enough that the second file has a strictly later creation time
        Thread.sleep(forTimeInterval: 1.1)
        try Data("main2".utf8).write(to: storeURL)
        let second = try CoreDataBackupManager.createTimestampedBackup(at: storeURL)

        let backups = CoreDataBackupManager.listBackups(for: storeURL)
        XCTAssertEqual(backups.count, 2)
        XCTAssertEqual(backups.first?.lastPathComponent, second.lastPathComponent)
        XCTAssertEqual(backups.last?.lastPathComponent, first.lastPathComponent)
    }

    func testListBackups_sortsTimestampedBackupsByEmbeddedTimestamp() throws {
        let newest = "Store.backup-2026-05-12T18-42-00Z.sqlite"
        let oldest = "Store.backup-2026-05-12T18-40-00Z.sqlite"
        let legacy = "legacy.sqlite"

        _ = try writeBackup(named: newest)
        _ = try writeBackup(named: legacy)
        _ = try writeBackup(named: oldest)

        let backupNames = CoreDataBackupManager.listBackups(for: storeURL)
            .map(\.lastPathComponent)

        XCTAssertEqual(backupNames, [newest, oldest, legacy])
    }

    func testListBackups_createdTimestampedBackupSortsBeforeNewerLegacyBackup() throws {
        let timestamped = try CoreDataBackupManager.createTimestampedBackup(at: storeURL)
        let legacy = try writeBackup(named: "legacy.sqlite", createdAt: Date(timeIntervalSinceNow: 3_600))

        let backupNames = CoreDataBackupManager.listBackups(for: storeURL)
            .map(\.lastPathComponent)

        XCTAssertEqual(backupNames, [timestamped.lastPathComponent, legacy.lastPathComponent])
    }

    func testListBackups_unparseableTimestampFallsBackToCreationDate() throws {
        let newer = "Store.backup-not-a-date.sqlite"
        let older = "legacy.sqlite"

        _ = try writeBackup(named: newer, createdAt: Date(timeIntervalSinceNow: 60))
        _ = try writeBackup(named: older, createdAt: Date(timeIntervalSinceNow: -60))

        let backupNames = CoreDataBackupManager.listBackups(for: storeURL)
            .map(\.lastPathComponent)

        XCTAssertEqual(backupNames, [newer, older])
    }

    func testListBackups_equalTimestampAndCreationDateFallsBackToFilename() throws {
        let creationDate = Date(timeIntervalSince1970: 1_800_000_000)
        let first = "AStore.backup-2026-05-12T18-42-00Z.sqlite"
        let second = "BStore.backup-2026-05-12T18-42-00Z.sqlite"

        _ = try writeBackup(named: first, createdAt: creationDate)
        _ = try writeBackup(named: second, createdAt: creationDate)

        let backupNames = CoreDataBackupManager.listBackups(for: storeURL)
            .map(\.lastPathComponent)

        XCTAssertEqual(backupNames, [first, second])
    }

    // MARK: - Cleanup Old Backups

    func testCleanupOldBackups_underKeepCount_keepsAll() throws {
        let backupsDir = tempDir.appendingPathComponent("Backups")
        try FileManager.default.createDirectory(at: backupsDir, withIntermediateDirectories: true)
        for index in 0..<2 {
            try Data().write(to: backupsDir.appendingPathComponent("b\(index).sqlite"))
        }

        CoreDataBackupManager.cleanupOldBackups(for: storeURL, keepCount: 3)

        let backups = CoreDataBackupManager.listBackups(for: storeURL)
        XCTAssertEqual(backups.count, 2)
    }

    func testCleanupOldBackups_overKeepCount_removesOldest() throws {
        // Create 4 backups with distinct timestamps
        var created: [URL] = []
        for index in 0..<4 {
            try Data("v\(index)".utf8).write(to: storeURL)
            let backup = try CoreDataBackupManager.createTimestampedBackup(at: storeURL)
            created.append(backup)
            Thread.sleep(forTimeInterval: 1.1)
        }

        CoreDataBackupManager.cleanupOldBackups(for: storeURL, keepCount: 2)

        let remaining = CoreDataBackupManager.listBackups(for: storeURL)
        XCTAssertEqual(remaining.count, 2)
        // Newest two should be retained — the last two created
        let remainingNames = Set(remaining.map { $0.lastPathComponent })
        XCTAssertTrue(remainingNames.contains(created[3].lastPathComponent))
        XCTAssertTrue(remainingNames.contains(created[2].lastPathComponent))
    }
}
