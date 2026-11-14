import Foundation

/// The file a pasted image is written to on its way to a reply's attachments (the Mac's
/// reply field; `MacReplyTextView`).
///
/// A copied image is bytes on the pasteboard with no file behind them, and the draft's import
/// reads files (`DocumentAttachmentImporter`). So the bytes are written to a file of the
/// app's own, the import is given that file, and the file is removed when the import ends
/// (`DraftFileDrop.temporaryFileURLs`). The import keeps its own copy in the attachments
/// folder, as it does for any file.
///
/// The file is in the temporary directory, each in a folder of its own, so the name the
/// attachment gets is the same for every paste and two pastes never share a file. It is the
/// user's own image, not mail, so it is not account data; it is still removed promptly, and a
/// file whose import never ran (the chat was closed first) goes at the next launch
/// (`removeAll`).
enum PastedImageFile {
    /// The folder in the temporary directory the files are in.
    static let folderName = "PastedImages"

    /// The attachment's name, before its extension.
    static let baseName = "Pasted Image"

    static func directory(fileManager: FileManager = .default) -> URL {
        fileManager.temporaryDirectory.appendingPathComponent(folderName, isDirectory: true)
    }

    /// Writes `data` as `Pasted Image.<fileExtension>` in a new folder under `directory`, and
    /// returns the file.
    static func write(
        _ data: Data,
        fileExtension: String,
        in directory: URL,
        fileManager: FileManager = .default
    ) throws -> URL {
        let folder = directory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("\(baseName).\(fileExtension)", isDirectory: false)
        do {
            try data.write(to: file, options: .atomic)
        } catch {
            try? fileManager.removeItem(at: folder)
            throw error
        }
        return file
    }

    /// Removes files `write` made, each with the folder it is alone in. A file that is
    /// already gone is passed over.
    static func remove(_ files: [URL], fileManager: FileManager = .default) {
        for file in files {
            try? fileManager.removeItem(at: file.deletingLastPathComponent())
        }
    }

    /// Removes every pasted image's file. At launch, when no import can be reading one.
    static func removeAll(in directory: URL? = nil, fileManager: FileManager = .default) {
        try? fileManager.removeItem(at: directory ?? self.directory(fileManager: fileManager))
    }
}
