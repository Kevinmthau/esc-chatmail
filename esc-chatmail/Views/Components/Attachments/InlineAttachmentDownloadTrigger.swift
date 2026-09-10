import SwiftUI
import CoreData

enum InlineAttachmentDownloadPolicy {
    static func pendingImages(
        in attachments: [ChatMessageAttachmentModel],
        isFromMe: Bool
    ) -> [ChatMessageAttachmentModel] {
        guard !isFromMe else { return [] }
        return attachments.filter {
            $0.isImage && $0.state == .queued &&
            ($0.width == 0 || $0.height == 0) &&
            EmailDocument.normalizedContentID($0.contentId) != nil
        }
    }
}

/// Signature filtering can remove the image view before its onAppear runs.
/// Keep queued inline downloads owned by the message, independent of visibility.
struct InlineAttachmentDownloadTrigger: View {
    let attachments: [ChatMessageAttachmentModel]
    @EnvironmentObject private var deps: Dependencies
    @Environment(\.managedObjectContext) private var viewContext

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .task(id: attachments.map(\.objectID)) {
                for model in attachments {
                    guard !Task.isCancelled else { return }
                    guard let attachment = try? viewContext.existingObject(with: model.objectID) as? Attachment,
                          !attachment.isDeleted else { continue }
                    await deps.attachmentDownloader.downloadAttachmentIfNeeded(for: attachment)
                }
            }
    }
}
