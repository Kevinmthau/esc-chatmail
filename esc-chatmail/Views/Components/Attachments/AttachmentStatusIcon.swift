import SwiftUI

struct AttachmentStatusIcon: View {
    let attachment: Attachment
    @ObservedObject var downloader: AttachmentDownloader

    private var indicator: AttachmentDownloadIndicatorPolicy.Indicator {
        AttachmentDownloadIndicatorPolicy.indicator(
            state: attachment.state,
            attachmentId: attachment.id,
            isReady: attachment.isReady,
            isDownloading: downloader.isDownloading(messageId: attachment.message?.id, attachmentId: attachment.id),
            isRefusedForSpace: downloader.isRefusedForSpace(messageId: attachment.message?.id, attachmentId: attachment.id)
        )
    }

    var body: some View {
        Group {
            switch indicator {
            case .uploading, .downloading:
                ProgressView()
                    .progressViewStyle(CircularProgressViewStyle())
                    .scaleEffect(0.8)
                    .frame(width: 20, height: 20)
            case .uploadFailed:
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundColor(.red)
                    .font(.system(size: 20))
            case .downloadFailed:
                Button(action: retry) {
                    Image(systemName: "exclamationmark.circle.fill")
                        .foregroundColor(.red)
                        .font(.system(size: 20))
                }
            case .refusedForSpace:
                AttachmentSpaceRefusalButton(onRetry: retry)
            case .notDownloaded, .none:
                EmptyView()
            }
        }
    }

    private func retry() {
        Task {
            await downloader.retryFailedDownload(for: attachment)
        }
    }
}
