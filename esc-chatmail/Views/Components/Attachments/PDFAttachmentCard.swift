import SwiftUI

struct PDFAttachmentCard: View {
    let attachment: Attachment
    @ObservedObject var downloader: AttachmentDownloader
    let onTap: () -> Void
    @StateObject private var thumbnailLoader = AttachmentThumbnailLoader()

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                // Thumbnail
                if let uiImage = thumbnailLoader.image {
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
                            Group {
                                if thumbnailLoader.isLoading {
                                    ProgressView()
                                } else {
                                    Image(systemName: "doc.fill")
                                        .foregroundColor(.gray)
                                }
                            }
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
            thumbnailLoader.load(
                attachmentId: attachment.id,
                messageId: attachment.message?.id,
                previewPath: attachment.previewURL
            )
            // Download if queued, failed, or file is missing from disk
            if attachment.state == .queued || attachment.state == .failed || attachment.needsRedownload {
                Task {
                    await downloader.downloadAttachmentIfNeeded(for: attachment)
                }
            }
        }
        .onDisappear {
            thumbnailLoader.cancel()
        }
        .onChange(of: attachment.previewURL) { _, newValue in
            // Reload when the persisted preview identity changes, including
            // migration away from a legacy path or clearing a stale preview.
            thumbnailLoader.load(
                attachmentId: attachment.id,
                messageId: attachment.message?.id,
                previewPath: newValue
            )
        }
    }
}
