import Foundation

/// Handles backup operations for Core Data stores.
enum CoreDataBackupManager {

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
        }.map(\.url)
    }

    /// Cleans up old backups, keeping only the most recent ones.
    /// - Parameters:
    ///   - storeURL: The URL of the main SQLite store file
    ///   - keepCount: Number of backups to keep (default: 3)
    static func cleanupOldBackups(for storeURL: URL, keepCount: Int = 3) {
        let backups = listBackups(for: storeURL)

        guard backups.count > keepCount else { return }

        for backup in backups.dropFirst(keepCount) {
            do {
                try removeStore(at: backup)
                Log.info("Removed old backup: \(backup.lastPathComponent)", category: .coreData)
            } catch {
                Log.warning("Failed to remove old backup: \(error.localizedDescription)", category: .coreData)
            }
        }
    }

    // MARK: - Private Helpers

    private struct BackupFile {
        let url: URL
        let timestamp: Date?
        let creationDate: Date
        let filename: String

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
