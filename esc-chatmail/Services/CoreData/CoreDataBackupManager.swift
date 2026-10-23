import Foundation

/// Handles backup operations for Core Data stores.
///
/// A backup is a whole copy of the mailbox, written before a reset or
/// migration recovery removes the store, and nothing in the app reads it back.
/// It is kept for a while as the last copy of queued PendingAction and
/// OutboundSendMutationRecord rows, then pruned (`pruneBackups`), and removed
/// with the mailbox at sign-out (`CoreDataStack.destroyAllData()`). Before
/// pruning, every backup stayed for good: on APFS the copy is a clone that
/// keeps every block of the removed store, so each reset doubled the app's
/// footprint once sync refilled the mailbox.
enum CoreDataBackupManager {

    /// How long the newest backup is kept once a store has opened again.
    static let retentionInterval: TimeInterval = 7 * 24 * 60 * 60

    /// Creates a timestamped backup of a SQLite store file and its associated files.
    /// - Parameter storeURL: The URL of the main SQLite store file
    /// - Returns: The URL of the created backup
    /// - Throws: File system errors if backup fails
    static func createTimestampedBackup(at storeURL: URL) throws -> URL {
        let timestamp = backupTimestampString(from: Date())
        let backupFilename = storeURL.deletingPathExtension()
            .appendingPathExtension("backup-\(timestamp).sqlite")
            .lastPathComponent

        // Create backups directory if it doesn't exist
        let backupsDir = storeURL.deletingLastPathComponent().appendingPathComponent("Backups")
        try? FileManager.default.createDirectory(at: backupsDir, withIntermediateDirectories: true)

        let backupPath = backupsDir.appendingPathComponent(backupFilename)

        // Copy main store file
        try FileManager.default.copyItem(at: storeURL, to: backupPath)

        // Copy associated SQLite files (-wal and -shm)
        copyAssociatedFiles(for: storeURL, to: backupPath)

        Log.info("Created timestamped backup at: \(backupPath.path)", category: .coreData)
        return backupPath
    }

    /// Removes a SQLite store and its associated files.
    /// - Parameter storeURL: The URL of the main SQLite store file
    /// - Throws: File system errors if removal fails
    static func removeStore(at storeURL: URL) throws {
        try FileManager.default.removeItem(at: storeURL)

        // Also remove journal files
        let walURL = URL(fileURLWithPath: storeURL.path + "-wal")
        let shmURL = URL(fileURLWithPath: storeURL.path + "-shm")
        try? FileManager.default.removeItem(at: walURL)
        try? FileManager.default.removeItem(at: shmURL)
    }

    /// Lists all available backups in the backups directory.
    /// - Parameter storeURL: The URL of the main SQLite store file
    /// - Returns: Array of backup URLs sorted by embedded timestamp, then creation date (newest first)
    static func listBackups(for storeURL: URL) -> [URL] {
        sortedBackupFiles(for: storeURL).map(\.url)
    }

    /// Cleans up old backups, keeping only the most recent ones.
    /// - Parameters:
    ///   - storeURL: The URL of the main SQLite store file
    ///   - keepCount: Number of backups to keep (default: 3)
    ///   - cutoff: Also removes kept backups dated before this, by the
    ///     timestamp in their name or else their creation date
    static func cleanupOldBackups(
        for storeURL: URL,
        keepCount: Int = 3,
        removingBackupsDatedBefore cutoff: Date? = nil
    ) {
        let backups = sortedBackupFiles(for: storeURL).enumerated().filter { index, backup in
            index >= keepCount || cutoff.map { backup.date < $0 } == true
        }.map(\.element.url)

        for backup in backups {
            do {
                try removeStore(at: backup)
                Log.info("Removed old backup: \(backup.lastPathComponent)", category: .coreData)
            } catch {
                Log.warning("Failed to remove old backup: \(error.localizedDescription)", category: .coreData)
            }
        }
    }

    /// Keeps only the newest backup, and drops that one too once it is older
    /// than `retentionInterval`. Runs whenever a store opens, which every
    /// reset and migration recovery is followed by.
    static func pruneBackups(for storeURL: URL, now: Date = Date()) {
        cleanupOldBackups(
            for: storeURL,
            keepCount: 1,
            removingBackupsDatedBefore: now.addingTimeInterval(-retentionInterval)
        )
    }

    /// Removes every backup of the store, for a teardown that removes the
    /// mailbox itself. Best-effort: failures are logged, not thrown.
    static func removeAllBackups(for storeURL: URL) {
        cleanupOldBackups(for: storeURL, keepCount: 0)
    }

    /// Backups sorted by embedded timestamp, then creation date (newest first).
    private static func sortedBackupFiles(for storeURL: URL) -> [BackupFile] {
        let backupsDir = storeURL.deletingLastPathComponent().appendingPathComponent("Backups")

        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: backupsDir,
            includingPropertiesForKeys: [.creationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        let backups = contents
            .filter { $0.pathExtension == "sqlite" }
            .map { BackupFile(url: $0, creationDate: creationDate(for: $0)) }

        return backups.sorted { lhs, rhs in
            if let lhsTimestamp = lhs.timestamp, let rhsTimestamp = rhs.timestamp, lhsTimestamp != rhsTimestamp {
                return lhsTimestamp > rhsTimestamp
            }

            if lhs.timestamp != nil && rhs.timestamp == nil {
                return true
            }

            if lhs.timestamp == nil && rhs.timestamp != nil {
                return false
            }

            if lhs.creationDate != rhs.creationDate {
                return lhs.creationDate > rhs.creationDate
            }

            return lhs.filename < rhs.filename
        }
    }

    // MARK: - Private Helpers

    private struct BackupFile {
        let url: URL
        let timestamp: Date?
        let creationDate: Date
        let filename: String

        /// When the backup was made: the timestamp in its name, or else its
        /// creation date (`.distantPast` when unreadable, so it expires).
        var date: Date {
            timestamp ?? creationDate
        }

        init(url: URL, creationDate: Date) {
            self.url = url
            self.timestamp = CoreDataBackupManager.backupTimestamp(from: url)
            self.creationDate = creationDate
            self.filename = url.lastPathComponent
        }
    }

    private static func creationDate(for url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
    }

    private static func backupTimestampString(from date: Date) -> String {
        makeBackupTimestampFormatter().string(from: date)
    }

    private static func backupTimestamp(from url: URL) -> Date? {
        let filename = url.lastPathComponent
        let sqliteSuffix = ".sqlite"

        guard filename.hasSuffix(sqliteSuffix),
              let backupMarker = filename.range(of: ".backup-", options: .backwards) else {
            return nil
        }

        let timestampEnd = filename.index(filename.endIndex, offsetBy: -sqliteSuffix.count)
        guard backupMarker.upperBound < timestampEnd else { return nil }

        let timestamp = String(filename[backupMarker.upperBound..<timestampEnd])
        return makeBackupTimestampFormatter().date(from: timestamp)
    }

    private static func makeBackupTimestampFormatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd'T'HH-mm-ss'Z'"
        return formatter
    }

    private static func copyAssociatedFiles(for sourceURL: URL, to destinationURL: URL) {
        let walSource = URL(fileURLWithPath: sourceURL.path + "-wal")
        let shmSource = URL(fileURLWithPath: sourceURL.path + "-shm")
        let walDest = URL(fileURLWithPath: destinationURL.path + "-wal")
        let shmDest = URL(fileURLWithPath: destinationURL.path + "-shm")

        try? FileManager.default.copyItem(at: walSource, to: walDest)
        try? FileManager.default.copyItem(at: shmSource, to: shmDest)
    }
}
