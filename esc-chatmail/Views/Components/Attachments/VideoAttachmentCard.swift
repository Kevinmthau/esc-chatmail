import AVFoundation
import SwiftUI

struct VideoAttachmentCard: View {
    let attachment: Attachment
    @ObservedObject var downloader: AttachmentDownloader
    let onTap: () -> Void

    @State private var thumbnailImage: UIImage?
    @State private var isLoadingThumbnail = false

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
        .onChange(of: attachment.localURL) { _, newValue in
            if newValue != nil {
                loadThumbnailIfNeeded()
            }
        }
    }

    @ViewBuilder
    private var videoThumbnail: some View {
        ZStack {
            if let image = thumbnailImage {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else if isLoadingThumbnail {
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
        let attachmentId = attachment.id ?? ""

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
        } else if downloader.activeDownloads.contains(attachmentId) {
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
        guard thumbnailImage == nil, !isLoadingThumbnail else { return }
        guard let localPath = attachment.localURL,
              let fileURL = AttachmentPaths.fullURL(for: localPath),
              FileManager.default.fileExists(atPath: fileURL.path) else {
            return
        }

        isLoadingThumbnail = true

        Task.detached(priority: .userInitiated) {
            let asset = AVAsset(url: fileURL)
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 400, height: 400)

            let time = CMTime(seconds: 0.5, preferredTimescale: 600)
            let cgImage = try? generator.copyCGImage(at: time, actualTime: nil)

            await MainActor.run {
                isLoadingThumbnail = false
                if let cgImage = cgImage {
                    thumbnailImage = UIImage(cgImage: cgImage)
                }
            }
        }
    }
}
