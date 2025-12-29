import SwiftUI

struct AttachmentGrid: View {
    let attachments: [Attachment]
    @ObservedObject var downloader: AttachmentDownloader
    let onTap: (Attachment) -> Void

    var columns: [GridItem] {
        let count = min(attachments.count, 3)
        return Array(repeating: GridItem(.flexible(), spacing: 4), count: count == 1 ? 1 : 2)
    }

    var body: some View {
        LazyVGrid(columns: columns, spacing: 4) {
            ForEach(attachments.prefix(6)) { attachment in
                AttachmentGridItem(
                    attachment: attachment,
                    downloader: downloader,
                    showOverlay: attachments.count > 6 && attachment == attachments[5],
                    overlayCount: attachments.count - 5,
                    onTap: { onTap(attachment) }
                )
            }
        }
        .cornerRadius(14)
    }
}
