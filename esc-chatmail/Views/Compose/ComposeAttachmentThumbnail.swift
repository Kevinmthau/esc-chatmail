import SwiftUI

struct ComposeAttachmentThumbnail: View {
    let attachment: Attachment
    let onRemove: () -> Void
    @State private var thumbnailImage: UIImage?
    private let cache = AttachmentCacheActor.shared

    var body: some View {
        ZStack(alignment: .topTrailing) {
            if let image = thumbnailImage {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 60, height: 60)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            } else {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.gray.opacity(0.2))
                    .frame(width: 60, height: 60)
                    .overlay(
                        Image(systemName: isPDF ? "doc.fill" : "photo")
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
        .onAppear {
            loadThumbnail()
        }
    }

    private var isPDF: Bool {
        return attachment.mimeTypeValue == "application/pdf"
    }

    private func loadThumbnail() {
        guard thumbnailImage == nil,
              let attachmentId = attachment.attachmentId else { return }

        Task {
            let previewPath = attachment.previewURLValue
            if let image = await cache.loadThumbnail(for: attachmentId, from: previewPath) {
                await MainActor.run {
                    self.thumbnailImage = image
                }
            }
        }
    }
}
