import SwiftUI

struct PDFAttachmentCard: View {
    let attachment: Attachment
    @ObservedObject var downloader: AttachmentDownloader
    let onTap: () -> Void
    @State private var thumbnailImage: UIImage?
    @State private var isLoadingImage = false
    private let cache = AttachmentCacheActor.shared

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                // Thumbnail
                if let previewURL = attachment.previewURL,
                   let previewData = AttachmentPaths.loadData(from: previewURL),
                   let uiImage = UIImage(data: previewData) {
                    Image(uiImage: uiImage)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 60, height: 80)
                        .cornerRadius(8)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(Color.gray.opacity(0.2), lineWidth: 0.5)
                        )
                } else {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.gray.opacity(0.1))
                        .frame(width: 60, height: 80)
                        .overlay(
                            Image(systemName: "doc.fill")
                                .foregroundColor(.gray)
                        )
                }

                // Info
                VStack(alignment: .leading, spacing: 4) {
                    Text(attachment.filename)
                        .font(.system(size: 14, weight: .medium))
                        .lineLimit(1)

                    HStack(spacing: 4) {
                        Text("PDF")
                            .font(.caption2)
                            .foregroundColor(.secondary)

                        if attachment.pageCount > 0 {
                            Text("•")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                            Text("\(attachment.pageCount) pages")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }

                        if attachment.byteSize > 0 {
                            Text("•")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                            Text(AttachmentViewHelpers.formatFileSize(attachment.byteSize))
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                    }
                }

                Spacer()

                // Status
                AttachmentStatusIcon(
                    attachment: attachment,
                    downloader: downloader
                )
            }
            .padding(12)
            .background(Color(UIColor.secondarySystemBackground))
            .cornerRadius(12)
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
