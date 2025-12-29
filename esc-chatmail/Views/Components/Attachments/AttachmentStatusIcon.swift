import SwiftUI

struct AttachmentStatusIcon: View {
    let attachment: Attachment
    @ObservedObject var downloader: AttachmentDownloader

    private var isLocalAttachment: Bool {
        (attachment.id)?.starts(with: "local_") == true
    }

    var body: some View {
        Group {
            if attachment.state == .uploading ||
               (attachment.state == .queued && isLocalAttachment) {
                ProgressView()
                    .progressViewStyle(CircularProgressViewStyle())
                    .scaleEffect(0.8)
                    .frame(width: 20, height: 20)
            } else if attachment.state == .failed {
                if isLocalAttachment {
                    // Upload failure - show error icon with "Send failed" tooltip
                    Image(systemName: "exclamationmark.circle.fill")
                        .foregroundColor(.red)
                        .font(.system(size: 20))
                } else {
                    // Download failure - allow retry
                    Button(action: {
                        Task {
                            await downloader.retryFailedDownload(for: attachment)
                        }
                    }) {
                        Image(systemName: "exclamationmark.circle.fill")
                            .foregroundColor(.red)
                            .font(.system(size: 20))
                    }
                }
            } else if let attachmentId = attachment.id,
                      downloader.activeDownloads.contains(attachmentId) {
                ProgressView()
                    .progressViewStyle(CircularProgressViewStyle())
                    .scaleEffect(0.8)
                    .frame(width: 20, height: 20)
            }
        }
    }
}
