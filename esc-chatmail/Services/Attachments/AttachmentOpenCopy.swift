import Foundation

/// The copy of an attachment that another app is given to open (the Mac's Open;
/// `MacAttachmentOpener`).
///
/// The attachment's own file is never opened in place, for two reasons. It is named for its
/// storage identity, and the other app would show that name. And the other app could change
/// it: Preview saves a markup into the file it has open, which here would be the app's copy
/// of the mail. So the file is copied, under the name a save would offer, and the copy is
/// read-only, which a document app shows as locked and offers to duplicate before an edit.
///
/// The copies are account data, and they are kept where account data already is:
/// `Attachments/Opened/` in Application Support. Sign-out and a fresh install remove the whole
/// `Attachments` directory, the check for files left from another account counts what is in
/// it (`AccountScopedMailboxFileInspector.hasStoredFiles`), and the orphan sweep removes the
/// `Opened` folder once nothing has been opened for its grace period (`AttachmentDownloader`,
/// `markInUse`). Never put them in the temporary directory, which none of those know.
///
/// Making a copy writes into that directory, so whatever makes one does it as registered
/// account work (`AttachmentAccountWorkRegistry`, as `MacAttachmentOpener` does): sign-out
/// drains that registry before it removes `Attachments`, and a copy made outside it could
/// land in the directory while it is being removed, or after.
///
/// Read-only by permission, never locked with the user-immutable flag: removing a directory
/// fails on a locked file inside it, and sign-out's removal of `Attachments` must not fail.
enum AttachmentOpenCopy {
    /// The folder under `Attachments` the copies are in.
    static let folderName = "Opened"

    /// Read for everyone, write for no one.
    static let readOnlyPermissions = 0o444

    /// Where the copies are kept. Nil where Application Support cannot be found.
    static func defaultDirectory() -> URL? {
        AttachmentPaths.fullURL(for: "\(AttachmentPaths.attachmentsFolder)/\(folderName)")
    }

    /// Makes the copy of `item` to open, or finds the one made the last time, and returns
    /// where it is.
    ///
    /// Each attachment has a folder of its own, named for its stored file, with the copy in
    /// it under the attachment's name: two attachments both called `image.jpg` do not share
    /// one, and opening the same attachment again makes no second copy.
    ///
    /// Every copy handed out, a new one or the one made before, moves the date of `directory`
    /// to `now` (`markInUse`): that date is what the orphan sweep reads.
    ///
    /// - Parameters:
    ///   - directory: Where the copies are kept. The tests give a temporary one.
    ///   - now: The time the folder of copies is marked as used at.
    static func prepare(
        _ item: AttachmentExportItem,
        in directory: URL,
        fileManager: FileManager = .default,
        now: Date = Date()
    ) throws -> URL {
        guard fileManager.fileExists(atPath: item.sourceURL.path) else {
            throw AttachmentFileExport.ExportError.sourceMissing(filename: item.filename)
        }
        let folder = directory.appendingPathComponent(folderName(for: item), isDirectory: true)
        let copy = folder.appendingPathComponent(item.filename, isDirectory: false)
        do {
            if isCurrent(copy, of: item, fileManager: fileManager) {
                markInUse(directory, at: now, fileManager: fileManager)
                return copy
            }
            // A copy that is not the attachment's (cut short, or left under another name)
            // goes with its folder. Removing it asks nothing of the file's own permissions.
            if fileManager.fileExists(atPath: folder.path) {
                try fileManager.removeItem(at: folder)
            }
            try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
            try fileManager.copyItem(at: item.sourceURL, to: copy)
            try fileManager.setAttributes([.posixPermissions: readOnlyPermissions], ofItemAtPath: copy.path)
            markInUse(directory, at: now, fileManager: fileManager)
            return copy
        } catch {
            throw AttachmentFileExport.ExportError.copyFailed(
                filename: item.filename,
                reason: error.localizedDescription
            )
        }
    }

    /// Moves the folder of copies' modification date to `date`.
    ///
    /// The orphan sweep (`AttachmentDownloader.cleanupOrphanedFiles`) removes the whole folder
    /// once its own dates are older than the sweep's grace period, and no attachment row
    /// names it. A new attachment's folder moves that date by being added, but a copy that is
    /// handed out again adds nothing, so without this an attachment opened a second time more
    /// than the grace period after the last new one was a file in a folder the next sweep
    /// removed, under the app it had just been handed to.
    ///
    /// A date that cannot be set is not a reason to refuse the Open: the copy is there. What
    /// is left then is what was there before, and no worse.
    ///
    /// HONEST SCOPE: a sweep that has already judged the folder old, and removes it in the
    /// moment after this, still wins. That needs the folder idle for the whole grace period
    /// and the Open inside the sweep's own run, and it costs one "could not be opened".
    static func markInUse(_ directory: URL, at date: Date, fileManager: FileManager = .default) {
        try? fileManager.setAttributes([.modificationDate: date], ofItemAtPath: directory.path)
    }

    /// The folder for one attachment's copy: its stored file's name, which is the
    /// attachment's storage identity and is already a plain file name.
    static func folderName(for item: AttachmentExportItem) -> String {
        item.sourceURL.lastPathComponent
    }

    /// Whether `copy` is there and is as long as the attachment's file. An attachment's
    /// stored file is written once, so a copy of the same length is taken to be whole.
    private static func isCurrent(
        _ copy: URL,
        of item: AttachmentExportItem,
        fileManager: FileManager
    ) -> Bool {
        guard let copySize = try? fileManager.attributesOfItem(atPath: copy.path)[.size] as? NSNumber,
              let sourceSize = try? fileManager.attributesOfItem(atPath: item.sourceURL.path)[.size] as? NSNumber else {
            return false
        }
        return copySize == sourceSize
    }
}
