import Foundation

/// Files dropped on a chat, on their way to its reply's attachments
/// (`DraftFileDropPolicy.decision`).
///
/// A request, not state: the composer's `AttachmentPicker` imports it once and clears it. The
/// `id` tells two drops of the same files apart.
struct DraftFileDrop: Equatable, Identifiable {
    let id: UUID
    /// The dropped files the reply can take, in the order they were dropped.
    let fileURLs: [URL]
    /// The names of the dropped files it cannot take, for the alert that says so.
    let unsupportedFilenames: [String]

    init(id: UUID = UUID(), fileURLs: [URL], unsupportedFilenames: [String]) {
        self.id = id
        self.fileURLs = fileURLs
        self.unsupportedFilenames = unsupportedFilenames
    }
}
