import CoreData
import Foundation

extension CoreDataStack {
    /// The files SQLite keeps for a store at `storeURL`: the database, its write-ahead log and
    /// its shared-memory index.
    static func storeFileURLs(for storeURL: URL) -> [URL] {
        ["", "-wal", "-shm"].map { URL(fileURLWithPath: storeURL.path + $0) }
    }

    /// Leaves the mailbox store out of device backups: its three files, through
    /// `BackupExclusion`, which on the Mac marks nothing outside the App Sandbox.
    ///
    /// The store holds the plain text of every body (`bodyText`) with subjects, snippets and
    /// headers: 0.7 to 1.0 GB of every backup at S2 and 2.5 to 4 GB at S3, by the scalability
    /// review's estimate. A restore to a new device threw it away on first launch anyway
    /// (`FreshInstallHandler` reads the missing this-device-only installation ID as a new
    /// install). Kevin chose to leave it out (2026-11-28, architecture review 2026-11,
    /// security-privacy#5), and accepted the cost: a same-device restore brings back no
    /// mailbox, re-lists up to `SyncConfig.initialSyncMaxWindow`, and loses drafts and queued
    /// actions. The store stays at its default URL: moving it would be a one-way path change
    /// that an older build sharing the container would read as an empty store.
    ///
    /// Called from both branches where a load attaches the store (`startClaimedStoreLoad` and
    /// `loadStoresAsync`), because the mark is each file's own and not its path's: a sign-out's
    /// `destroyAllData`, the recovery ladder's reset, Reset Mailbox and a migration all make the
    /// files again, and each such file is new and unmarked until the load that follows it. All
    /// three, or a backup could hold a log without its database. A store that is not a SQLite
    /// file (an in-memory test store) is left alone, and so is a file that is not there.
    static func leaveStoreFilesOutOfBackups(for description: NSPersistentStoreDescription) {
        guard description.type == NSSQLiteStoreType,
              let storeURL = description.url,
              storeURL.isFileURL,
              storeURL.path != "/dev/null" else {
            return
        }
        for fileURL in storeFileURLs(for: storeURL)
        where FileManager.default.fileExists(atPath: fileURL.path) {
            BackupExclusion.exclude(fileURL, category: .coreData)
        }
    }
}
