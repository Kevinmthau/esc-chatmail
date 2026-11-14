import Foundation

/// The file a pasted image is written to on its way to a reply's attachments (the Mac's
/// reply field; `MacReplyTextView`).
///
/// A copied image is bytes on the pasteboard with no file behind them, and the draft's import
/// reads files (`DocumentAttachmentImporter`). So the bytes are written to a file of the
/// app's own, the import is given that file, and the file is removed when the import ends
/// (`DraftFileDrop.temporaryFiles`). The import keeps its own copy in the attachments
/// folder, as it does for any file.
///
/// The file is in the temporary directory, each in a folder of its own, so the name the
/// attachment gets is the same for every paste and two pastes never share a file. It is the
/// user's own image, not mail, so it is not account data; it is still removed promptly, and a
/// file whose import never ran (the chat was closed first) goes at the next launch
/// (`removeAll`).
///
/// A value of this type is a file `write` made, and nothing else can make one: the
/// initializer is private. `remove` takes the folder a file is in, so what it is handed must
/// be a file whose folder is the app's to remove. While a request carried its temporary files
/// as plain URLs, only a comment kept a user's own file from being put among them, and then
/// only the shape of its path kept `remove` from taking the user's folder (reviews of PR 421
/// and PR 422, 2026-11-14). Now a user's file cannot be handed to `remove` at all.
struct PastedImageFile: Equatable {
    /// The folder in the temporary directory the files are in.
    static let folderName = "PastedImages"

    /// The attachment's name, before its extension.
    static let baseName = "Pasted Image"

    /// Where the file is.
    let url: URL

    /// Private, so that `write` is the only source of a value (the type's comment).
    private init(url: URL) {
        self.url = url
    }

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
    ) throws -> PastedImageFile {
        let folder = directory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("\(baseName).\(fileExtension)", isDirectory: false)
        do {
            try data.write(to: file, options: .atomic)
        } catch {
            try? fileManager.removeItem(at: folder)
            throw error
        }
        return PastedImageFile(url: file)
    }

    /// Removes each file with the folder `write` made for it.
    ///
    /// The folder goes where it holds the file and nothing else, and where it holds nothing:
    /// the file is already gone, and its folder was only ever for it. As first guarded, an
    /// empty folder was passed over and stayed until the next launch (review of PR 422,
    /// 2026-11-14). A folder that holds anything else is not as `write` left it, and is left.
    static func remove(_ files: [PastedImageFile], fileManager: FileManager = .default) {
        for file in files {
            let folder = file.url.deletingLastPathComponent()
            guard let contents = try? fileManager.contentsOfDirectory(atPath: folder.path) else {
                continue
            }
            if contents == [file.url.lastPathComponent] {
                try? fileManager.removeItem(at: folder)
            } else if contents.isEmpty {
                // `rmdir` removes a folder only while it is empty, so nothing that arrived
                // since it was listed can go with it.
                _ = rmdir(folder.path)
            }
        }
    }

    /// Removes every pasted image's file. At launch, when no import can be reading one.
    static func removeAll(in directory: URL? = nil, fileManager: FileManager = .default) {
        try? fileManager.removeItem(at: directory ?? self.directory(fileManager: fileManager))
    }
}
