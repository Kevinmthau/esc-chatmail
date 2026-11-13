import Foundation

/// An attachment as a save takes it: where its file is and the name to save it under. A value,
/// read from the managed object when the user asks, so nothing of the object is held while a
/// save panel is open.
struct AttachmentExportItem: Equatable {
    let sourceURL: URL
    let filename: String

    init(sourceURL: URL, filename: String) {
        self.sourceURL = sourceURL
        self.filename = filename
    }

    /// Nil for an attachment with no file of its own on disk: one still downloading, one whose
    /// file is gone, or one whose stored path is a legacy one no reader may use
    /// (`readableLocalURLValue`).
    ///
    /// Only the attachment's own file is saved. Quick Look falls back to the preview image
    /// where the file is missing (`AttachmentPreviewItem`); a save does not, because the
    /// preview of a document is a picture of its first page under the document's name.
    ///
    /// - Parameters:
    ///   - resolveURL: Where a stored relative path is on disk. The tests keep their files in
    ///     a temporary directory with it.
    init?(
        attachment: Attachment,
        resolveURL: (String?) -> URL? = { AttachmentPaths.fullURL(for: $0) },
        fileExists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }
    ) {
        guard Self.isLive(attachment),
              attachment.isReady,
              let sourceURL = resolveURL(attachment.readableLocalURLValue),
              fileExists(sourceURL) else {
            return nil
        }
        self.sourceURL = sourceURL
        self.filename = Self.exportFilename(of: attachment)
    }

    /// The name a save, a drag or Open gives the attachment's file, whether or not it has
    /// that file yet: the attachment's menu asks before the download ends, to know its kind
    /// (`AttachmentOpenPolicy`).
    static func exportFilename(of attachment: Attachment) -> String {
        guard isLive(attachment) else { return AttachmentExportPolicy.fallbackBaseName }
        // The type's extension, not the stored file's: that one is whatever followed the last
        // dot of the sender's name (`AttachmentExportPolicy.filename`).
        return AttachmentExportPolicy.filename(
            storedFilename: attachment.filename,
            typeExtension: AttachmentPaths.fileExtension(for: attachment.mimeType)
        )
    }

    /// The name to report an attachment under when it has no file to save.
    static func displayFilename(of attachment: Attachment) -> String {
        guard isLive(attachment) else { return AttachmentExportPolicy.fallbackBaseName }
        return AttachmentExportPolicy.filename(storedFilename: attachment.filename, typeExtension: "")
    }

    /// The attachments of a message as Save All takes them: a value for each that has its
    /// file, and the names of those that should have one and do not. An attachment still
    /// downloading is neither: its menu entry does not count it.
    static func resolve(
        _ attachments: [Attachment],
        resolveItem: (Attachment) -> AttachmentExportItem? = { AttachmentExportItem(attachment: $0) }
    ) -> (items: [AttachmentExportItem], missingFilenames: [String]) {
        var items: [AttachmentExportItem] = []
        var missingFilenames: [String] = []
        for attachment in attachments where isLive(attachment) && attachment.isReady {
            if let item = resolveItem(attachment) {
                items.append(item)
            } else {
                missingFilenames.append(displayFilename(of: attachment))
            }
        }
        return (items, missingFilenames)
    }

    /// False for a row sync deleted while the menu that names it was open: its properties are
    /// no longer there to read.
    private static func isLive(_ attachment: Attachment) -> Bool {
        !attachment.isDeleted && attachment.managedObjectContext != nil
    }
}
