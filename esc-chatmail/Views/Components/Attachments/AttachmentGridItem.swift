import SwiftUI

struct AttachmentGridItem: View {
    let attachment: Attachment
    @ObservedObject var downloader: AttachmentDownloader
    let showOverlay: Bool
    let overlayCount: Int
    let onTap: () -> Void
    @State private var thumbnailImage: UIImage?
    @State private var isLoadingImage = false
    private let cache = AttachmentCache.shared

    var body: some View {
        Button(action: {
            // Only allow tap if downloaded or uploaded
            if attachment.isReady {
                onTap()
            }
        }) {
            GeometryReader { geometry in
                ZStack {
                    if let image = thumbnailImage {
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
                                    if isLoadingImage {
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
            loadThumbnail()
            if attachment.state == .queued {
                Task {
                    await downloader.downloadAttachmentIfNeeded(for: attachment)
                }
            }
        }
    }

    private func loadThumbnail() {
        guard thumbnailImage == nil,
              !isLoadingImage,
              let attachmentId = attachment.id else { return }

        isLoadingImage = true
        Task {
            let previewPath = attachment.previewURL
            let targetSize = CGSize(width: 200, height: 200) // Grid items are small

            // Try to load downsampled for grid view
            if let localPath = attachment.localURL,
               attachment.isImage {
                if let image = await cache.loadDownsampledImage(
                    for: attachmentId,
                    from: localPath,
                    targetSize: targetSize
                ) {
                    await MainActor.run {
                        self.thumbnailImage = image
                        self.isLoadingImage = false
                    }
                    return
                }
            }

            // Fall back to preview
            if let image = await cache.loadThumbnail(for: attachmentId, from: previewPath) {
                await MainActor.run {
                    self.thumbnailImage = image
                    self.isLoadingImage = false
                }
            } else {
                await MainActor.run {
                    self.isLoadingImage = false
                }
            }
        }
    }
}
