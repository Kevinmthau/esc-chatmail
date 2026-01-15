import SwiftUI

struct AttachmentGridItem: View {
    let attachment: Attachment
    @ObservedObject var downloader: AttachmentDownloader
    let showOverlay: Bool
    let overlayCount: Int
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
                    if let image = thumbnailLoader.image {
                        Image(uiImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: geometry.size.width, height: geometry.size.height)
                            .clipped()
                    } else {
                        Rectangle()
                            .fill(Color.gray.opacity(0.1))
                            .overlay(
                                Group {
                                    if thumbnailLoader.isLoading {
                                        ProgressView()
                                            .progressViewStyle(CircularProgressViewStyle())
                                            .scaleEffect(0.6)
                                    } else {
                                        Image(systemName: attachment.isPDF ? "doc.fill" : "photo")
                                            .foregroundColor(.gray)
                                    }
                                }
                            )
                    }

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
            thumbnailLoader.loadDownsampled(
                attachmentId: attachment.id,
                localPath: attachment.localURL,
                previewPath: attachment.previewURL,
                targetSize: CGSize(width: 200, height: 200),
                isImage: attachment.isImage
            )
            if attachment.state == .queued {
                Task {
                    await downloader.downloadAttachmentIfNeeded(for: attachment)
                }
            }
        }
        .onChange(of: attachment.localURL) { oldValue, newValue in
            // Reload when localURL becomes available after download (preferred over previewURL)
            if newValue != nil && thumbnailLoader.image == nil {
                thumbnailLoader.reset()
                thumbnailLoader.loadDownsampled(
                    attachmentId: attachment.id,
                    localPath: newValue,
                    previewPath: attachment.previewURL,
                    targetSize: CGSize(width: 200, height: 200),
                    isImage: attachment.isImage
                )
            }
        }
        .onDisappear {
            thumbnailLoader.cancel()
        }
    }
}
