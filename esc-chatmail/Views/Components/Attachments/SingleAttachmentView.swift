import SwiftUI

struct SingleAttachmentView: View {
    let attachment: Attachment
    @ObservedObject var downloader: AttachmentDownloader
    let onTap: () -> Void

    var body: some View {
        Group {
            if attachment.isImage {
                ImageAttachmentBubble(
                    attachment: attachment,
                    downloader: downloader,
                    onTap: {
                        // Only allow tap if downloaded or uploaded
                        if attachment.isReady {
                            onTap()
                        }
                    }
                )
            } else if attachment.isPDF {
                PDFAttachmentCard(
                    attachment: attachment,
                    downloader: downloader,
                    onTap: {
                        // Only allow tap if downloaded or uploaded
                        if attachment.isReady {
                            onTap()
                        }
                    }
                )
            }
        }
    }
}
