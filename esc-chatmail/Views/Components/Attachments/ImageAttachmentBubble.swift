import SwiftUI

struct ImageAttachmentBubble: View {
    let attachment: Attachment
    @ObservedObject var downloader: AttachmentDownloader
    let onTap: () -> Void
    @State private var thumbnailImage: UIImage?
    @State private var isLoadingImage = false

    private let maxWidth = UIScreen.main.bounds.width * 0.65
    private let cache = AttachmentCacheActor.shared

    var isDownloading: Bool {
        if let attachmentId = attachment.id {
            return downloader.activeDownloads.contains(attachmentId)
        }
        return false
    }

    var body: some View {
        Button(action: onTap) {
            ZStack {
                if let image = thumbnailImage {
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(maxWidth: maxWidth)
                        .cornerRadius(14)
                        .overlay(
                            RoundedRectangle(cornerRadius: 14)
                                .stroke(Color.gray.opacity(0.2), lineWidth: 0.5)
                        )
                } else if isLoadingImage {
                    RoundedRectangle(cornerRadius: 14)
                        .fill(Color.gray.opacity(0.1))
                        .frame(width: 200, height: 150)
                        .overlay(
                            ProgressView()
                                .progressViewStyle(CircularProgressViewStyle())
                        )
                } else {
                    RoundedRectangle(cornerRadius: 14)
                        .fill(Color.gray.opacity(0.1))
                        .frame(width: 200, height: 150)
                        .overlay(
                            VStack {
                                Image(systemName: "photo")
                                    .font(.system(size: 30))
                                    .foregroundColor(.gray)
                                Text(attachment.filename)
                                    .font(.caption)
                                    .foregroundColor(.gray)
                            }
                        )
                }

                // Status overlay
                AttachmentStatusOverlay(
                    attachment: attachment,
                    downloader: downloader
                )
            }
        }
        .buttonStyle(PlainButtonStyle())
        .opacity([.downloaded, .uploaded, .failed].contains(attachment.state) ? 1.0 : 0.7)
        .disabled(!attachment.isReady)
        .onAppear {
            loadThumbnail()
            if attachment.state == .queued {
                Task {
                    await downloader.downloadAttachmentIfNeeded(for: attachment)
                }
            }
        }
        .onDisappear {
            // Cancel loading if view disappears
            isLoadingImage = false
        }
    }

    private func loadThumbnail() {
        guard thumbnailImage == nil,
              !isLoadingImage,
              let attachmentId = attachment.id else { return }

        isLoadingImage = true
        Task {
            let previewPath = attachment.previewURL
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
