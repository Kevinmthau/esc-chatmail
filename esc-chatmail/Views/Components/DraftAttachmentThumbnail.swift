import SwiftUI

/// Shared presentation for locally-selected compose and reply attachments.
struct DraftAttachmentThumbnail: View {
    @ObservedObject var attachment: Attachment
    let onRemove: () -> Void

    @StateObject private var thumbnailLoader = AttachmentThumbnailLoader()
    @State private var activeLoadKey: LoadKey?
    @Environment(\.displayScale) private var displayScale

    /// The thumbnail's frame, which its preview is decoded to cover (`ThumbnailDecodeSize`).
    private static let thumbnailFrame = CGSize(width: 60, height: 60)

    private struct LoadKey: Equatable {
        let objectIdentity: ObjectIdentifier
        let attachmentId: String?
        let messageId: String?
        let previewPath: String?
    }

    private var loadKey: LoadKey {
        LoadKey(
            objectIdentity: ObjectIdentifier(attachment),
            attachmentId: attachment.attachmentId,
            messageId: attachment.message?.id,
            previewPath: attachment.previewURLValue
        )
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            if activeLoadKey == loadKey, let image = thumbnailLoader.image {
                Image(platformImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: Self.thumbnailFrame.width, height: Self.thumbnailFrame.height)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            } else {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.gray.opacity(0.2))
                    .frame(width: Self.thumbnailFrame.width, height: Self.thumbnailFrame.height)
                    .overlay(
                        Image(systemName: placeholderIconName)
                            .foregroundColor(.gray)
                    )
            }

            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 18))
                    .foregroundColor(.white)
                    .background(Circle().fill(Color.black.opacity(0.5)))
            }
            .offset(x: 4, y: -4)
        }
        .task(id: loadKey) {
            if activeLoadKey != loadKey {
                thumbnailLoader.reset()
            }
            thumbnailLoader.load(
                attachmentId: loadKey.attachmentId,
                messageId: loadKey.messageId,
                previewPath: loadKey.previewPath,
                decodeSize: ThumbnailDecodeSize(points: Self.thumbnailFrame, displayScale: displayScale)
            )
            activeLoadKey = loadKey
        }
        .onDisappear {
            thumbnailLoader.cancel()
            activeLoadKey = nil
        }
    }

    private var placeholderIconName: String {
        if attachment.isImage {
            return "photo"
        }
        if attachment.isVideo {
            return "video.fill"
        }
        return "doc.fill"
    }
}
