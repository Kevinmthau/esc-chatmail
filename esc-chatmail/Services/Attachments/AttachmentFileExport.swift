import Foundation

/// Copies an attachment's file to where the user chose to save it (`MacAttachmentExporter`).
/// The app's own copy is never moved or changed.
enum AttachmentFileExport {
    enum ExportError: LocalizedError, Equatable {
        /// The attachment's file was gone when the copy began: removed since the menu was
        /// opened, by a sign-out or by storage cleanup.
        case sourceMissing(filename: String)
        /// The copy failed; `reason` is the system's.
        case copyFailed(filename: String, reason: String)

        var errorDescription: String? {
            switch self {
            case .sourceMissing(let filename):
                return "\(filename) is no longer on this Mac."
            case .copyFailed(let filename, let reason):
                return "\(filename) could not be saved. \(reason)"
            }
        }
    }

    /// Saves one attachment at `destination`, the file the save panel returned. A file already
    /// there is replaced: the panel asked.
    ///
    /// The file being replaced is never removed first. The attachment is copied beside it, in
    /// the directory the system gives for replacing an item on that volume, and takes its
    /// place only once the copy is whole, so a copy that fails (a full disk, a file a sign-out
    /// deleted meanwhile) leaves the user the file they had.
    static func save(
        _ item: AttachmentExportItem,
        to destination: URL,
        fileManager: FileManager = .default
    ) throws {
        guard fileManager.fileExists(atPath: item.sourceURL.path) else {
            throw ExportError.sourceMissing(filename: item.filename)
        }
        do {
            guard fileManager.fileExists(atPath: destination.path) else {
                try fileManager.copyItem(at: item.sourceURL, to: destination)
                return
            }
            let holding = try fileManager.url(
                for: .itemReplacementDirectory,
                in: .userDomainMask,
                appropriateFor: destination,
                create: true
            )
            defer { try? fileManager.removeItem(at: holding) }
            let staged = holding.appendingPathComponent(destination.lastPathComponent)
            try fileManager.copyItem(at: item.sourceURL, to: staged)
            _ = try fileManager.replaceItemAt(destination, withItemAt: staged)
        } catch {
            throw ExportError.copyFailed(
                filename: destination.lastPathComponent,
                reason: error.localizedDescription
            )
        }
    }

    /// Writes an attachment dragged out of the chat at `destination`, the place the app it
    /// was dropped on asked for (`MacAttachmentFilePromiseProvider`). Nothing is replaced: no
    /// one was asked, and a file already there fails the copy.
    static func writePromise(
        _ item: AttachmentExportItem,
        to destination: URL,
        fileManager: FileManager = .default
    ) throws {
        guard fileManager.fileExists(atPath: item.sourceURL.path) else {
            throw ExportError.sourceMissing(filename: item.filename)
        }
        do {
            try fileManager.copyItem(at: item.sourceURL, to: destination)
        } catch {
            throw ExportError.copyFailed(
                filename: destination.lastPathComponent,
                reason: error.localizedDescription
            )
        }
    }

    /// Saves each attachment into `folder` under its own name, and returns the ones that could
    /// not be saved. Nothing in the folder is replaced: a name already there, or used by an
    /// earlier attachment of the same save, gets a number
    /// (`AttachmentExportPolicy.availableFilename`).
    static func saveAll(
        _ items: [AttachmentExportItem],
        into folder: URL,
        fileManager: FileManager = .default
    ) -> [ExportError] {
        var failures: [ExportError] = []
        for item in items {
            guard fileManager.fileExists(atPath: item.sourceURL.path) else {
                failures.append(.sourceMissing(filename: item.filename))
                continue
            }
            // Asked of the folder itself each time, so an attachment saved a moment ago counts.
            let name = AttachmentExportPolicy.availableFilename(item.filename) { candidate in
                fileManager.fileExists(atPath: folder.appendingPathComponent(candidate).path)
            }
            do {
                try fileManager.copyItem(at: item.sourceURL, to: folder.appendingPathComponent(name))
            } catch {
                failures.append(.copyFailed(filename: name, reason: error.localizedDescription))
            }
        }
        return failures
    }

    /// The alert's text for failed saves, one line each.
    static func failureMessage(for failures: [ExportError]) -> String {
        failures.compactMap(\.errorDescription).joined(separator: "\n")
    }
}
