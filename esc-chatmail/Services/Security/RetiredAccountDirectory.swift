import Foundation

/// Takes a directory of account files out of use in one rename, and removes it afterwards.
///
/// A sign-out used to unlink every message body and every attachment file while it held the
/// auth-transition gate: about 150,000 unlinks for a mailbox of 60,000 messages, seconds to
/// tens of seconds in which the sign-out's spinner ran and the next sign-in waited
/// (scalability review step 7, `signout-o-n-file-deletion`). The same loop ran at launch
/// after an interrupted sign-out, and in the fresh-install cleanup before the app started.
///
/// Now the directory is renamed to a sibling, a tombstone (`Messages.deleting-<UUID>`), which
/// is one operation however much is in it, and the tombstone is removed by a background
/// task. The directory is made again, empty, by whatever reopens it for the next account.
///
/// Four things hold this together:
///
/// - **A tombstone is not account data any more.** No stored path leads into one: body files
///   are looked for in `Messages` and attachment paths start at `Attachments` or `Previews`.
///   So the checks for files another account left
///   (`AccountScopedMailboxFileInspector.hasStoredFiles`,
///   `HTMLContentHandler.hasStoredHTMLFiles`) look in the live directories only and do not
///   count tombstones. Counting them would make the sign-in that follows a sign-out reset
///   the store again, for files it can never be shown.
/// - **The removal is not part of the account boundary** and is never waited for. It touches
///   nothing but the tombstone it was given, whose name no other code makes, so it cannot
///   remove a file of the next account, and a transition has nothing of it to drain. The
///   rename is the part inside the boundary: it runs where the unlinks ran, after the
///   writers have been closed and drained.
/// - **The files are on disk until the removal ends.** A process killed before then leaves
///   the tombstone, so every launch removes the ones it finds (`sweepLeftovers`).
/// - **A rename that fails is not a failed sign-out.** The directory is then emptied in
///   place, as before, except that one file that cannot be removed no longer stops the rest.
///
/// On the Mac the renames are behind the tripwire guards of the functions that make them
/// (`SandboxTripwire`), and the launch sweep has a guard of its own.
enum RetiredAccountDirectory {
    /// What a tombstone's name has between the directory's name and its UUID.
    static let tombstoneMarker = ".deleting-"

    // MARK: - Taking a directory out of use

    /// Takes `directory` out of use and returns its tombstone, which the caller hands to
    /// `removeInBackground`. Nil where there was no directory, and where the rename failed
    /// and the directory was emptied in place.
    ///
    /// - Throws: Only from the fallback: the first error of an item that could not be
    ///   removed, after every other item has been.
    static func takeOutOfUse(_ directory: URL, fileManager: FileManager = .default) throws -> URL? {
        guard fileManager.fileExists(atPath: directory.path) else { return nil }
        let tombstone = directory.deletingLastPathComponent().appendingPathComponent(
            "\(directory.lastPathComponent)\(tombstoneMarker)\(UUID().uuidString)",
            isDirectory: true
        )
        do {
            // Same parent, so the same volume: a rename, never a copy.
            try fileManager.moveItem(at: directory, to: tombstone)
        } catch {
            Log.warning(
                "Could not rename \(directory.lastPathComponent) out of use; emptying it in place",
                category: .auth
            )
            try removeContents(of: directory, fileManager: fileManager)
            return nil
        }
        // `Attachments` is marked file by file, so its tombstone would otherwise be backed
        // up for as long as it is there.
        BackupExclusion.exclude(tombstone, category: .auth)
        return tombstone
    }

    /// Removes everything in `directory`, going on past an item that cannot be removed, and
    /// throws the first such error once the rest is gone.
    static func removeContents(of directory: URL, fileManager: FileManager = .default) throws {
        let contents: [URL]
        do {
            contents = try fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        } catch let error as CocoaError
            where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
            return
        }
        var firstError: Error?
        for item in contents {
            do {
                try fileManager.removeItem(at: item)
            } catch {
                firstError = firstError ?? error
            }
        }
        if let firstError {
            throw firstError
        }
    }

    // MARK: - Removing a tombstone

    /// Whether `url` is named as a tombstone: a name, the marker, a UUID.
    static func isTombstone(_ url: URL) -> Bool {
        let name = url.lastPathComponent
        guard let marker = name.range(of: tombstoneMarker, options: .backwards),
              marker.lowerBound > name.startIndex else {
            return false
        }
        return UUID(uuidString: String(name[marker.upperBound...])) != nil
    }

    /// The tombstones of `directory` that are on disk.
    static func tombstones(of directory: URL, fileManager: FileManager = .default) -> [URL] {
        let parent = directory.deletingLastPathComponent()
        let prefix = "\(directory.lastPathComponent)\(tombstoneMarker)"
        let siblings = (try? fileManager.contentsOfDirectory(at: parent, includingPropertiesForKeys: nil)) ?? []
        return siblings.filter { $0.lastPathComponent.hasPrefix(prefix) && isTombstone($0) }
    }

    /// Removes `tombstone` and everything in it, going on past an item that cannot be
    /// removed. Returns whether it is gone. Refuses anything not named as a tombstone: this
    /// is the one function here that unlinks a tree, and it is handed URLs.
    @discardableResult
    static func remove(_ tombstone: URL, fileManager: FileManager = .default) -> Bool {
        guard isTombstone(tombstone) else {
            Log.error("Refusing to remove \(tombstone.lastPathComponent): not a tombstone", category: .auth)
            return false
        }
        if (try? fileManager.removeItem(at: tombstone)) != nil {
            return true
        }
        // `removeItem` stops at the first item it cannot remove.
        removeTree(at: tombstone, fileManager: fileManager)
        return !fileManager.fileExists(atPath: tombstone.path)
    }

    private static func removeTree(at directory: URL, fileManager: FileManager) {
        let contents = (try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey]
        )) ?? []
        for item in contents {
            let isDirectory = (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if isDirectory {
                removeTree(at: item, fileManager: fileManager)
            } else {
                try? fileManager.removeItem(at: item)
            }
        }
        try? fileManager.removeItem(at: directory)
    }

    /// Starts the removal of `tombstone` and returns at once. Nothing waits for it.
    static func removeInBackground(_ tombstone: URL?) {
        guard let tombstone else { return }
        Task.detached(priority: .background) {
            if !remove(tombstone) {
                Log.warning(
                    "A retired account directory could not be removed; the next launch tries again",
                    category: .auth
                )
            }
        }
    }

    // MARK: - Leftovers

    /// Every directory a cleanup takes out of use, for the launch sweep to look beside.
    static func accountDirectories(fileManager: FileManager = .default) -> [URL] {
        var directories: [URL] = []
        if let documents = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first {
            directories.append(documents.appendingPathComponent("Messages", isDirectory: true))
            // Where attachments were kept before they moved to Application Support.
            directories.append(documents.appendingPathComponent("Attachments", isDirectory: true))
        }
        if let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            directories.append(appSupport.appendingPathComponent(AttachmentPaths.attachmentsFolder, isDirectory: true))
            directories.append(appSupport.appendingPathComponent(AttachmentPaths.previewsFolder, isDirectory: true))
        }
        if let caches = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first {
            directories.append(
                caches.appendingPathComponent(AttachmentPaths.legacyAttachmentCacheFolder, isDirectory: true)
            )
        }
        return directories
    }

    /// Removes, in the background, the tombstones an earlier run of the app left: one whose
    /// removal was cut short by the app being closed, or by the device restarting. Called at
    /// every launch. It is not an account transition and takes no part in one.
    ///
    /// Returns the task doing the removal (nil where the Mac's tripwire refused the sweep).
    /// The launch discards it: nothing in the app waits for the sweep. It is returned for a
    /// test, which must await it rather than poll the disk against a deadline: the task runs
    /// at background priority, which the system runs only when higher-priority work leaves
    /// room, and on a loaded CI runner it had not finished after a 5-second wait (PRs 463 and
    /// 470). Awaiting it waits for as long as it takes.
    @discardableResult
    static func sweepLeftovers(beside directories: [URL]? = nil) -> Task<Void, Never>? {
        #if os(macOS)
        // Outside the App Sandbox these are the user's own Documents and the shared
        // Application Support. No cleanup makes a tombstone there, because each is
        // refused first, but nothing is removed on that reasoning alone.
        guard SandboxTripwire.permitsDestructiveCleanup(.retiredAccountDirectorySweep) else {
            return nil
        }
        #endif
        let directories = directories ?? accountDirectories()
        return Task.detached(priority: .background) {
            for directory in directories {
                for tombstone in tombstones(of: directory) {
                    remove(tombstone)
                }
            }
        }
    }
}
