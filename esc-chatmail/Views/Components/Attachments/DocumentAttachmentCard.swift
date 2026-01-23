import QuickLookThumbnailing
import SwiftUI

struct DocumentAttachmentCard: View {
    let attachment: Attachment
    @ObservedObject var downloader: AttachmentDownloader
    let onTap: () -> Void

    @State private var thumbnailImage: UIImage?
    @State private var isLoadingThumbnail = false

    private var isLocalAttachment: Bool {
        (attachment.id)?.starts(with: "local_") == true
    }

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                // Document icon thumbnail (native iOS style)
                documentThumbnail
                    .frame(width: 48, height: 60)

                // File info
                VStack(alignment: .leading, spacing: 2) {
                    Text(attachment.filename)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    if attachment.byteSize > 0 {
                        Text(AttachmentViewHelpers.formatFileSize(attachment.byteSize))
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                    }
                }

                Spacer()

                // Download status indicator
                downloadIndicator
            }
            .padding(12)
            .background(Color(UIColor.secondarySystemBackground))
            .cornerRadius(12)
        }
        .buttonStyle(PlainButtonStyle())
        .onAppear {
            loadThumbnail()
            triggerDownloadIfNeeded()
        }
        .onChange(of: attachment.localURL) { _, newValue in
            if newValue != nil {
                loadThumbnail()
            }
        }
    }

    @ViewBuilder
    private var documentThumbnail: some View {
        if let image = thumbnailImage {
            Image(uiImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
        } else if isLoadingThumbnail {
            ZStack {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color(UIColor.tertiarySystemFill))
                ProgressView()
                    .scaleEffect(0.6)
            }
        } else {
            // Fallback: generic document icon
            ZStack {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color(UIColor.tertiarySystemFill))
                Image(systemName: "doc.fill")
                    .font(.system(size: 24))
                    .foregroundColor(.gray)
            }
        }
    }

    @ViewBuilder
    private var downloadIndicator: some View {
        let attachmentId = attachment.id ?? ""

        if attachment.state == .uploading || (attachment.state == .queued && isLocalAttachment) {
            // Uploading
            ProgressView()
                .progressViewStyle(CircularProgressViewStyle())
                .scaleEffect(0.8)
                .frame(width: 24, height: 24)
        } else if attachment.state == .failed {
            if isLocalAttachment {
                // Upload failure
                Image(systemName: "exclamationmark.circle.fill")
                    .font(.system(size: 22))
                    .foregroundColor(.red)
            } else {
                // Download failure - allow retry
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
        } else if downloader.activeDownloads.contains(attachmentId) {
            // Actively downloading - show spinner
            ProgressView()
                .progressViewStyle(CircularProgressViewStyle())
                .scaleEffect(0.8)
                .frame(width: 24, height: 24)
        } else if !attachment.isReady && !isLocalAttachment {
            // Not downloaded yet - show cloud download icon (like Mail)
            Image(systemName: "icloud.and.arrow.down")
                .font(.system(size: 22))
                .foregroundColor(.blue)
        }
        // When downloaded: show nothing (like Mail)
    }

    private func loadThumbnail() {
        guard let localPath = attachment.localURL,
              let fileURL = AttachmentPaths.fullURL(for: localPath),
              FileManager.default.fileExists(atPath: fileURL.path) else {
            return
        }

        isLoadingThumbnail = true

        let request = QLThumbnailGenerator.Request(
            fileAt: fileURL,
            size: CGSize(width: 48, height: 60),
            scale: UIScreen.main.scale,
            representationTypes: .icon
        )

        QLThumbnailGenerator.shared.generateRepresentations(for: request) { thumbnail, _, _ in
            DispatchQueue.main.async {
                isLoadingThumbnail = false
                if let thumbnail = thumbnail {
                    thumbnailImage = thumbnail.uiImage
                }
            }
        }
    }

    private func triggerDownloadIfNeeded() {
        if attachment.state == .queued || attachment.state == .failed || attachment.needsRedownload {
            Task {
                await downloader.downloadAttachmentIfNeeded(for: attachment)
            }
        }
    }
}
