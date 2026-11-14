import Foundation

/// Files dropped on a chat, or pasted into its reply field, on their way to the reply's
/// attachments (`DraftFileDropPolicy.decision`).
///
/// A request, not state: the composer's `AttachmentPicker` imports it once and clears it. The
/// `id` tells two drops of the same files apart.
struct DraftFileDrop: Equatable, Identifiable {
    let id: UUID
    /// The dropped files the reply can take, in the order they were dropped.
    let fileURLs: [URL]
    /// The names of the dropped files it cannot take, for the alert that says so.
    let unsupportedFilenames: [String]
    /// Files the app wrote only to carry this request: a pasted image, which has no file of
    /// its own (`PastedImageFile`). Whoever imports the request removes them when the import
    /// ends, whatever it ended with. Empty for a drop and for pasted files, which are the
    /// user's own and are never removed: none of them can be put here, because only
    /// `PastedImageFile.write` makes a value of this type.
    let temporaryFiles: [PastedImageFile]

    init(
        id: UUID = UUID(),
        fileURLs: [URL],
        unsupportedFilenames: [String],
        temporaryFiles: [PastedImageFile] = []
    ) {
        self.id = id
        self.fileURLs = fileURLs
        self.unsupportedFilenames = unsupportedFilenames
        self.temporaryFiles = temporaryFiles
    }
}
