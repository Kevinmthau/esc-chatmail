import SwiftUI

struct SingleAttachmentView: View {
    let attachment: Attachment
    @ObservedObject var downloader: AttachmentDownloader
    var imagePresentation: InlineImagePresentationPolicy = .standard
    let onTap: () -> Void

    var body: some View {
        Group {
            if attachment.isImage {
                ImageAttachmentBubble(
                    attachment: attachment,
                    downloader: downloader,
                    presentation: imagePresentation,
                    onTap: {
                        // Only allow tap if downloaded or uploaded
                        if attachment.isReady {
                            onTap()
                        }
                    }
                )
                // The reserved geometry and loader belong to this attachment,
                // even if the message replaces its only attachment in place.
                .id(attachment.objectID)
            } else if attachment.isVideo {
                VideoAttachmentCard(
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
            } else {
                DocumentAttachmentCard(
                    attachment: attachment,
                    downloader: downloader,
                    onTap: {
                        if attachment.isReady {
                            onTap()
                        }
                    }
                )
            }
        }
    }
}
