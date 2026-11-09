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

    /// The previewed files, in order, for a URL-based Quick Look (the Mac's `.quickLookPreview`).
    var itemURLs: [URL] {
        previewItems.compactMap(\.previewItemURL)
    }

    /// The file Quick Look opens on, for a URL-based Quick Look.
    var selectedItemURL: URL? {
        guard previewItems.indices.contains(selectedIndex) else { return nil }
        return previewItems[selectedIndex].previewItemURL
    }
}
