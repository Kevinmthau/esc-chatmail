import SwiftUI

struct VideoAttachmentCard: View {
    let attachment: Attachment
    @ObservedObject var downloader: AttachmentDownloader
    let onTap: () -> Void

    /// Poster-frame loading routes through the shared loader seam: request
    /// identity, cancel-keeps-image on disappear (no re-decode churn on
    /// scroll-backs), deinit cancellation if SwiftUI destroys the card
    /// without onDisappear, and frames cached in AttachmentCacheActor's
    /// budgeted, memory-pressure-evictable thumbnail LRU.
    @StateObject private var thumbnailLoader = AttachmentThumbnailLoader()

    private let thumbnailSize = CGSize(width: 100, height: 60)

    private var isLocalAttachment: Bool {
        attachment.isLocalAttachment
    }

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                videoThumbnail
                    .frame(width: thumbnailSize.width, height: thumbnailSize.height)

                VStack(alignment: .leading, spacing: 4) {
                    Text(attachment.filename)
                        .font(.system(size: 14, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.middle)

                    HStack(spacing: 4) {
                        Text(videoLabel)
                            .font(.caption2)
                            .foregroundColor(.secondary)

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

                downloadIndicator
            }
            .padding(12)
            .background(Color(UIColor.secondarySystemBackground))
            .cornerRadius(12)
        }
        .buttonStyle(PlainButtonStyle())
        .onAppear {
            loadThumbnailIfNeeded()
            triggerDownloadIfNeeded()
        }
        .onChange(of: attachment.localURL) { _, _ in
            // A changed source invalidates the displayed frame: full reset
            // (discards the image), then reload from the new file.
            thumbnailLoader.reset()
            loadThumbnailIfNeeded()
        }
        .onDisappear {
            // Cancel keeps the decoded image so a scroll-back re-renders
            // instantly instead of re-extracting the frame.
            thumbnailLoader.cancel()
        }
    }

    @ViewBuilder
    private var videoThumbnail: some View {
        ZStack {
            if let image = thumbnailLoader.image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else if thumbnailLoader.isLoading {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(UIColor.tertiarySystemFill))
                    .overlay(
                        ProgressView()
                            .scaleEffect(0.7)
                    )
            } else {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(UIColor.tertiarySystemFill))
                    .overlay(
                        Image(systemName: "video.fill")
                            .font(.system(size: 22))
                            .foregroundColor(.gray)
                    )
            }

            Image(systemName: "play.circle.fill")
                .font(.system(size: 26))
                .foregroundColor(.white)
                .shadow(radius: 2)
        }
        .frame(width: thumbnailSize.width, height: thumbnailSize.height)
        .clipped()
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.gray.opacity(0.2), lineWidth: 0.5)
        )
    }

    @ViewBuilder
    private var downloadIndicator: some View {
        if attachment.state == .uploading || (attachment.state == .queued && isLocalAttachment) {
            ProgressView()
                .progressViewStyle(CircularProgressViewStyle())
                .scaleEffect(0.8)
                .frame(width: 24, height: 24)
        } else if attachment.state == .failed {
            if isLocalAttachment {
                Image(systemName: "exclamationmark.circle.fill")
                    .font(.system(size: 22))
                    .foregroundColor(.red)
            } else {
                Button(action: {
                    Task {
                        await downloader.retryFailedDownload(for: attachment)
                    }
                }) {
                    Image(systemName: "exclamationmark.circle.fill")
                        .font(.system(size: 22))
                        .foregroundColor(.red)
                }
            }
        } else if downloader.isDownloading(
            messageId: attachment.message?.id,
            attachmentId: attachment.id
        ) {
            ProgressView()
                .progressViewStyle(CircularProgressViewStyle())
                .scaleEffect(0.8)
                .frame(width: 24, height: 24)
        } else if !attachment.isReady && !isLocalAttachment {
            Image(systemName: "icloud.and.arrow.down")
                .font(.system(size: 22))
                .foregroundColor(.blue)
        }
    }

    private var videoLabel: String {
        let ext = (attachment.filename as NSString).pathExtension.uppercased()
        return ext.isEmpty ? "Video" : ext
    }

    private func triggerDownloadIfNeeded() {
        if attachment.state == .queued || attachment.state == .failed || attachment.needsRedownload {
            Task {
                await downloader.downloadAttachmentIfNeeded(for: attachment)
            }
        }
    }

    private func loadThumbnailIfNeeded() {
        thumbnailLoader.loadVideoThumbnail(
            attachmentId: attachment.id,
            messageId: attachment.message?.id,
            localPath: attachment.readableLocalURLValue,
            targetSize: thumbnailSize
        )
    }
}
