import Foundation

/// Marks what a device backup (iCloud Backup, a Finder backup, Time Machine) should leave out:
/// the mailbox, all of it, which at a large mailbox is most of what the app stores.
///
/// What is marked: the mail store's three files (`CoreDataStack.leaveStoreFilesOutOfBackups`,
/// after every load), and the `Messages`, `Attachments`, `Previews`, `Avatars` and store
/// `Backups` directories, each whole (scalability review, step 7; the store and `Attachments`
/// since 2026-11-28, architecture review 2026-11, security-privacy#5, Kevin's call). Inside
/// `Attachments` the downloaded files also carry a mark of their own
/// (`AttachmentPaths.applyBackupPolicy`), which is what a copy of one carries out of the
/// directory; the originals of attachments the user added carry none. So a restore brings
/// back no mailbox: on the same device the app re-lists up to `SyncConfig.initialSyncMaxWindow`
/// and loses drafts and queued actions, the cost Kevin accepted, and on a new device
/// `FreshInstallHandler` wiped a restored store on first launch anyway. The store and the
/// `local_` originals go together: a restored original with no store is a mailbox file with no
/// row, and the isolation gate answers it with a full reset that moves the mailbox's start.
///
/// Three things about the mark, each measured on macOS 27.2 (APFS) and none of them on a device:
///
/// - It is on the file or directory itself, not on its path. A directory that is removed and
///   made again has none, so every place that creates one of the marked directories marks it,
///   and marks it each time, whether or not it made the directory: an installation from
///   before the mark existed has the directories already.
/// - A file written atomically is a new file and has none, so a downloaded attachment is
///   marked after each write (`AttachmentPaths.saveData`), and the store's files after each
///   load: a sign-out, a reset and a migration make them again.
/// - `FileManager.copyItem` copies it. A marked attachment copied to a place of the user's
///   (Save Attachment…, a drag to the Finder) would be left out of the user's own backups
///   there, so such a copy has the mark taken off (`include`); and so does a copy that
///   becomes a file the app cannot download again (the copy a forward makes).
///
/// The mark is advice to the backup and changes nothing else: a marked file is not purgeable,
/// and the system never removes it.
///
/// On the Mac nothing is marked outside the App Sandbox (`marksFiles`). There the directories
/// the app looks up are the user's own `~/Documents/Messages` and `~/Documents/Avatars` and
/// the Application Support every app shares, and a mark would take a folder of the user's
/// out of Time Machine without a word. It is the same question the cleanups ask before they
/// delete (`SandboxTripwirePolicy`), asked here of a write that deletes nothing now and
/// loses the folder at the next restore.
enum BackupExclusion {
    /// Whether this process may mark files at all. Always on iOS, where every app is
    /// sandboxed; on the Mac only inside an App Sandbox container.
    static func marksFiles(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        #if os(macOS)
        return SandboxTripwirePolicy.destructiveCleanupVerdict(environment: environment) == .permitted
        #else
        return true
        #endif
    }

    /// Leaves `url` out of backups, with everything in it where it is a directory.
    /// Best effort: a failure is logged and the item is backed up as before.
    @discardableResult
    static func exclude(_ url: URL, category: LogCategory = .general) -> Bool {
        setExcluded(true, for: url, category: category)
    }

    /// Puts `url` back into backups, where it was left out. Asks first, so the common case,
    /// a file with no mark, is one read.
    @discardableResult
    static func include(_ url: URL, category: LogCategory = .general) -> Bool {
        guard isExcluded(url) else { return true }
        return setExcluded(false, for: url, category: category)
    }

    /// Whether `url` itself carries the mark. A file in a marked directory answers for
    /// itself here: the directory's mark is what keeps it out of a backup.
    static func isExcluded(_ url: URL) -> Bool {
        // A fresh URL: resource values are cached on the instance they were read through.
        let fresh = URL(fileURLWithPath: url.path)
        return (try? fresh.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup) ?? false
    }

    private static func setExcluded(_ excluded: Bool, for url: URL, category: LogCategory) -> Bool {
        guard marksFiles() else { return false }
        var target = URL(fileURLWithPath: url.path)
        var values = URLResourceValues()
        values.isExcludedFromBackup = excluded
        do {
            try target.setResourceValues(values)
            return true
        } catch {
            Log.warning(
                "Could not \(excluded ? "exclude" : "include") \(url.lastPathComponent) \(excluded ? "from" : "in") backups",
                category: category
            )
            return false
        }
    }
}
