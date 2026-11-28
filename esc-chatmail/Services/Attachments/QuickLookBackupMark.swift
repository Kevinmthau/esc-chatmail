import Foundation

/// The backup mark of the files Quick Look is shown.
///
/// Quick Look is handed the stored attachment itself (`AttachmentPreviewItem`), and its share
/// button hands that file on: to Save to Files on the iPhone, to the share menu on the Mac. A
/// downloaded attachment carries the mark that leaves it out of device backups
/// (`BackupExclusion`), and `FileManager.copyItem` copies the mark with the file, so a copy
/// the user saved from Quick Look could have been left out of the user's own backups. So
/// while Quick Look shows a file, the file has no mark, and the mark goes back on when Quick
/// Look closes.
///
/// A file left without its mark, because the app was ended with Quick Look open, is still left
/// out of backups by the `Attachments` directory's mark (since 2026-11-28, `security-privacy#5`),
/// and the daily orphan sweep gives it its own mark back
/// (`AttachmentDownloader.leaveOutOfBackupsIfDownloaded`), which is what a copy of it carries
/// out of the directory. Only a file in `Attachments`
/// carries a mark of its own. A preview in `Previews` is left out by its directory's mark,
/// which a copy does not carry, and is left alone.
///
/// HONEST SCOPE: whether a destination of the share sheet copies the mark was not measured.
/// This makes the question moot for a share made while Quick Look is open, which is the only
/// way Quick Look shares.
enum QuickLookBackupMark {
    /// Takes the mark off each of `urls`, the files a Quick Look about to be shown pages
    /// through.
    static func handOver(_ urls: [URL]) {
        for url in urls {
            BackupExclusion.include(url, category: .attachment)
        }
    }

    /// Gives each of `urls` the mark its name calls for again
    /// (`AttachmentPaths.applyBackupPolicy`), once the Quick Look that showed them is gone.
    static func takeBack(_ urls: [URL]) {
        for url in urls {
            guard let relativePath = AttachmentPaths.relativePath(from: url) else { continue }
            AttachmentPaths.applyBackupPolicy(toFileAt: relativePath)
        }
    }
}
