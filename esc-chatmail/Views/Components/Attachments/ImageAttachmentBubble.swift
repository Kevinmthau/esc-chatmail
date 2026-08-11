import SwiftUI

struct ImageAttachmentBubble: View {
    let attachment: Attachment
    @ObservedObject var downloader: AttachmentDownloader
    let onTap: () -> Void
    @StateObject private var thumbnailLoader = AttachmentThumbnailLoader()

    private let maxWidth = UIScreen.main.bounds.width * 0.65

    var body: some View {
        Button(action: onTap) {
            ZStack {
                if let image = thumbnailLoader.image {
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(maxWidth: maxWidth)
                        .cornerRadius(14)
                        .overlay(
                            RoundedRectangle(cornerRadius: 14)
                                .stroke(Color.gray.opacity(0.2), lineWidth: 0.5)
                        )
                } else if thumbnailLoader.isLoading {
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
        .onChange(of: attachment.previewURL) { _, newValue in
            // Path identity participates in the loader request, so migration
            // must replace any image decoded from the previous path.
            thumbnailLoader.load(
                attachmentId: attachment.id,
                messageId: attachment.message?.id,
                previewPath: newValue
            )
        }
        .onDisappear {
            thumbnailLoader.cancel()
        }
    }
}
