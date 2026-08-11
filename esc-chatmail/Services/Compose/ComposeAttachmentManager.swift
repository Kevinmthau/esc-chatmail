import Foundation
import CoreData
import Combine

struct ForwardAttachmentSnapshot: Equatable {
    let filename: String
    let mimeType: String
    let byteSize: Int64
    let localURL: String?
    let previewURL: String?
    let width: Int16
    let height: Int16
    let pageCount: Int16
}

/// Handles attachment lifecycle including cleanup of local files
@MainActor
final class ComposeAttachmentManager: ObservableObject {
    @Published var attachments: [Attachment] = []
    @Published private(set) var isImportingAttachments = false

    private let viewContext: NSManagedObjectContext
    private var activeImportIDs: Set<UUID> = []

    init(viewContext: NSManagedObjectContext = CoreDataStack.shared.viewContext) {
        self.viewContext = viewContext
    }

    func addAttachment(_ attachment: Attachment) {
        attachments.append(attachment)
    }

    func setImportInProgress(_ isInProgress: Bool, id: UUID) {
        if isInProgress {
            activeImportIDs.insert(id)
        } else {
            activeImportIDs.remove(id)
        }

        let hasActiveImports = !activeImportIDs.isEmpty
        if isImportingAttachments != hasActiveImports {
            isImportingAttachments = hasActiveImports
        }
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

    /// Copies a forwarded attachment into local draft state.
    /// Returns nil if the attachment data is not available (for example not downloaded).
    func copyAttachmentForForward(_ snapshot: ForwardAttachmentSnapshot) -> Attachment? {
        // Load the original attachment data
        guard let data = AttachmentPaths.loadData(from: snapshot.localURL) else {
            Log.warning("Cannot copy attachment for forward: not downloaded", category: .attachment)
            return nil
        }

        // Generate new local ID and paths
        let newId = "local_\(UUID().uuidString)"
        let ext = AttachmentPaths.fileExtension(for: snapshot.mimeType)
        let newPath = AttachmentPaths.originalPath(idOrUUID: newId, ext: ext)

        // Save the copied file
        guard AttachmentPaths.saveData(data, to: newPath) else {
            Log.error("Failed to save copied attachment for forward", category: .attachment)
            return nil
        }

        // Copy preview if available
        var newPreviewPath: String?
        if let originalPreview = snapshot.previewURL,
           let previewData = AttachmentPaths.loadData(from: originalPreview) {
            let previewPath = AttachmentPaths.previewPath(idOrUUID: newId)
            if AttachmentPaths.saveData(previewData, to: previewPath) {
                newPreviewPath = previewPath
            }
        }

        // Create new attachment entity
        let newAttachment = Attachment(context: viewContext)
        newAttachment.setValue(newId, forKey: "id")
        newAttachment.setValue(snapshot.filename, forKey: "filename")
        newAttachment.setValue(snapshot.mimeType, forKey: "mimeType")
        newAttachment.setValue(snapshot.byteSize, forKey: "byteSize")
        newAttachment.setValue(newPath, forKey: "localURL")
        newAttachment.setValue(newPreviewPath, forKey: "previewURL")
        newAttachment.setValue("queued", forKey: "stateRaw")
        newAttachment.setValue(snapshot.width, forKey: "width")
        newAttachment.setValue(snapshot.height, forKey: "height")
        newAttachment.setValue(snapshot.pageCount, forKey: "pageCount")

        return newAttachment
    }
}
