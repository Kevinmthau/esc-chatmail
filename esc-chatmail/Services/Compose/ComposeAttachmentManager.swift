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
}
