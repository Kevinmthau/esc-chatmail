import SwiftUI

struct ImageAttachmentBubble: View {
    let attachment: Attachment
    @ObservedObject var downloader: AttachmentDownloader
    @Environment(\.displayScale) private var displayScale
    let onTap: () -> Void
    @StateObject private var thumbnailLoader = AttachmentThumbnailLoader()
    @State private var reservedPixelSize: CGSize
    @State private var reservedPresentation: InlineImagePresentationPolicy

    private var maxWidth: CGFloat {
        min(UIScreen.main.bounds.width * 0.65, MessageBubbleStyle.standard.maxBubbleWidth)
    }

    init(
        attachment: Attachment,
        downloader: AttachmentDownloader,
        presentation: InlineImagePresentationPolicy = .standard,
        onTap: @escaping () -> Void
    ) {
        self.attachment = attachment
        self.downloader = downloader
        self.onTap = onTap
        // Downloads can fill in dimensions, and analysis or failure can change the
        // compact policy. Keep this mounted attachment's geometry through those
        // transitions; a fresh mount uses the latest metadata and cached analysis.
        _reservedPixelSize = State(initialValue: CGSize(
            width: CGFloat(attachment.width), height: CGFloat(attachment.height)
        ))
        _reservedPresentation = State(initialValue: presentation)
    }

    var body: some View {
        let size = ImageAttachmentLayout.size(
            pixelWidth: reservedPixelSize.width,
            pixelHeight: reservedPixelSize.height,
            maxWidth: maxWidth,
            displayScale: displayScale,
            presentation: reservedPresentation
        )
        Button(action: onTap) {
            ImageAttachmentBubbleContent(
                image: thumbnailLoader.image,
                isLoading: thumbnailLoader.isLoading,
                filename: attachment.filename,
                presentation: reservedPresentation,
                size: size
            )
            .overlay {
                // An overlay cannot enlarge the image's reserved frame.
                AttachmentStatusOverlay(
                    attachment: attachment,
                    downloader: downloader
                )
            }
        }
        .buttonStyle(PlainButtonStyle())
        .opacity([.downloaded, .uploaded, .failed].contains(attachment.state) ? 1.0 : 0.7)
        .disabled(!attachment.isReady && attachment.state != .failed)
        .onAppear {
            thumbnailLoader.load(
                attachmentId: attachment.id,
                messageId: attachment.message?.id,
                previewPath: attachment.previewURL
            )
            // Download if queued, failed, or file is missing from disk
            let waitsForRetry = InlineImagePresentationPolicy.requiresExplicitRetry(
                attachment: attachment, isFromMe: attachment.message?.isFromMe ?? false
            )
            if attachment.state == .queued || (attachment.state == .failed && !waitsForRetry) || attachment.needsRedownload {
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

/// Pure presentation shared by cold, cached, and failed thumbnail loads. The outer
/// frame belongs to the attachment metadata, never to the image or placeholder.
struct ImageAttachmentBubbleContent: View {
    let image: UIImage?
    let isLoading: Bool
    let filename: String
    let presentation: InlineImagePresentationPolicy
    let size: CGSize

    var body: some View {
        let padding: CGFloat = presentation == .compact ? min(8, size.width / 2) : 0
        ZStack {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(
                        width: max(0, size.width - padding * 2),
                        height: max(0, size.height - padding * 2)
                    )
            } else if isLoading {
                ProgressView()
                    .progressViewStyle(CircularProgressViewStyle())
            } else {
                VStack(spacing: 4) {
                    Image(systemName: "photo")
                        .font(.system(size: 30))
                    Text(filename)
                        .font(.caption)
                        .lineLimit(2)
                }
                .foregroundColor(.gray)
                .padding(8)
            }
        }
        .frame(width: size.width, height: size.height)
        .background(backgroundColor)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .stroke(Color.gray.opacity(0.2), lineWidth: 0.5)
        }
    }

    private var backgroundColor: Color {
        if presentation == .compact {
            return MessageBubbleStyle.standard.recipientBubbleColor()
        }
        return image == nil ? Color.gray.opacity(0.1) : .clear
    }
}
