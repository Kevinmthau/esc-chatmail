import Foundation

struct QuickLookPresentation: Identifiable {
    let id = UUID()
    let previewItems: [AttachmentPreviewItem]
    let selectedIndex: Int

    init?(attachments: [Attachment], selectedAttachment: Attachment) {
        let previewItems = attachments.compactMap { attachment in
            AttachmentPreviewItem(attachment: attachment)
        }
        guard let selectedIndex = previewItems.firstIndex(where: {
            $0.attachment == selectedAttachment
        }) else {
            return nil
        }

        self.previewItems = previewItems
        self.selectedIndex = selectedIndex
    }
}
