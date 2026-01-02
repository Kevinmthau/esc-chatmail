import Foundation
import CoreData
import Combine

/// Handles attachment lifecycle including cleanup of local files
@MainActor
final class ComposeAttachmentManager: ObservableObject {
    @Published var attachments: [Attachment] = []

    private let viewContext: NSManagedObjectContext

    init(viewContext: NSManagedObjectContext = CoreDataStack.shared.viewContext) {
        self.viewContext = viewContext
    }

    func addAttachment(_ attachment: Attachment) {
        attachments.append(attachment)
    }

    func removeAttachment(_ attachment: Attachment) {
        guard let index = attachments.firstIndex(of: attachment) else { return }
        let removed = attachments.remove(at: index)

        // Clean up files if it's a local attachment
        if let attachmentId = removed.attachmentId,
           attachmentId.starts(with: "local_") {
            if let localURL = removed.localURLValue {
                AttachmentPaths.deleteFile(at: localURL)
            }
            if let previewURL = removed.previewURLValue {
                AttachmentPaths.deleteFile(at: previewURL)
            }
        }

        viewContext.delete(removed)
    }

    func clear() {
        // Clean up all local attachments
        for attachment in attachments {
            if let attachmentId = attachment.attachmentId,
               attachmentId.starts(with: "local_") {
                if let localURL = attachment.localURLValue {
                    AttachmentPaths.deleteFile(at: localURL)
                }
                if let previewURL = attachment.previewURLValue {
                    AttachmentPaths.deleteFile(at: previewURL)
                }
            }
            viewContext.delete(attachment)
        }
        attachments.removeAll()
    }

    /// Copies an existing attachment for forwarding
    /// Returns nil if the attachment data is not available (not downloaded)
    func copyAttachmentForForward(_ original: Attachment) -> Attachment? {
        // Load the original attachment data
        guard let data = AttachmentPaths.loadData(from: original.localURLValue) else {
            Log.warning("Cannot copy attachment for forward: not downloaded", category: .attachment)
            return nil
        }

        // Generate new local ID and paths
        let newId = "local_\(UUID().uuidString)"
        let ext = AttachmentPaths.fileExtension(for: original.mimeTypeValue)
        let newPath = AttachmentPaths.originalPath(idOrUUID: newId, ext: ext)

        // Save the copied file
        guard AttachmentPaths.saveData(data, to: newPath) else {
            Log.error("Failed to save copied attachment for forward", category: .attachment)
            return nil
        }

        // Copy preview if available
        var newPreviewPath: String?
        if let originalPreview = original.previewURLValue,
           let previewData = AttachmentPaths.loadData(from: originalPreview) {
            let previewPath = AttachmentPaths.previewPath(idOrUUID: newId)
            if AttachmentPaths.saveData(previewData, to: previewPath) {
                newPreviewPath = previewPath
            }
        }

        // Create new attachment entity
        let newAttachment = Attachment(context: viewContext)
        newAttachment.setValue(newId, forKey: "id")
        newAttachment.setValue(original.filenameValue, forKey: "filename")
        newAttachment.setValue(original.mimeTypeValue, forKey: "mimeType")
        newAttachment.setValue(original.byteSize, forKey: "byteSize")
        newAttachment.setValue(newPath, forKey: "localURL")
        newAttachment.setValue(newPreviewPath, forKey: "previewURL")
        newAttachment.setValue("queued", forKey: "stateRaw")
        newAttachment.setValue(original.width, forKey: "width")
        newAttachment.setValue(original.height, forKey: "height")
        newAttachment.setValue(original.pageCount, forKey: "pageCount")

        return newAttachment
    }
}
