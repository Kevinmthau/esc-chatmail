import SwiftUI

struct AttachmentGridItem: View {
    let attachment: Attachment
    @ObservedObject var downloader: AttachmentDownloader
    let showOverlay: Bool
    let overlayCount: Int
    var imagePresentation: InlineImagePresentationPolicy = .standard
    let onTap: () -> Void
    @StateObject private var thumbnailLoader = AttachmentThumbnailLoader()

    var body: some View {
        Button(action: {
            // Only allow tap if downloaded or uploaded
            if attachment.isReady {
                onTap()
            }
        }) {
            GeometryReader { geometry in
                ZStack {
                    AttachmentGridThumbnail(
                        image: thumbnailLoader.image,
                        backdrop: thumbnailLoader.imageBackdrop,
                        isLoading: thumbnailLoader.isLoading,
                        placeholderIconName: placeholderIconName,
                        presentation: imagePresentation,
                        pixelSize: CGSize(width: CGFloat(attachment.width), height: CGFloat(attachment.height)),
                        cellSize: geometry.size
                    )

                    if showOverlay {
                        Rectangle()
                            .fill(Color.black.opacity(0.6))
                            .overlay(
                                Text("+\(overlayCount)")
                                    .font(.title2)
                                    .fontWeight(.semibold)
                                    .foregroundColor(.white)
                            )
                    }

                    AttachmentStatusOverlay(
                        attachment: attachment,
                        downloader: downloader
                    )
                }
            }
            .aspectRatio(1, contentMode: .fit)
        }
        .buttonStyle(PlainButtonStyle())
        .onAppear {
            loadThumbnail()
            // Download if queued, failed, or file is missing from disk
            let waitsForRetry = InlineImagePresentationPolicy.requiresExplicitRetry(
                attachment: attachment, isFromMe: attachment.message?.isFromMe ?? false
            )
            if attachment.state == .queued || (attachment.state == .failed && !waitsForRetry) || attachment.needsRedownload {
                Task {
                    await downloader.downloadAttachmentIfNeeded(for: attachment)
                }
            }
        }
        .onChange(of: attachment.localURL) { _, _ in
            loadThumbnail()
        }
        .onChange(of: attachment.previewURL) { _, _ in
            loadThumbnail()
        }
        .onDisappear {
            thumbnailLoader.cancel()
        }
    }

    private var placeholderIconName: String {
        if attachment.isImage {
            return "photo"
        }
        if attachment.isVideo {
            return "video.fill"
        }
        return "doc.fill"
    }

    private func loadThumbnail() {
        thumbnailLoader.loadDownsampled(
            attachmentId: attachment.id,
            messageId: attachment.message?.id,
            localPath: attachment.localURL,
            previewPath: attachment.previewURL,
            targetSize: CGSize(width: 200, height: 200),
            isImage: attachment.isImage
        )
    }
}
