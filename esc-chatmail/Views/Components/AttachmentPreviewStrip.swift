import SwiftUI

/// Horizontal scrolling strip for attachment previews
/// Generic over thumbnail view to support different thumbnail implementations
struct AttachmentPreviewStrip<Thumbnail: View>: View {
    let attachments: [Attachment]
    @ViewBuilder let thumbnail: (Attachment) -> Thumbnail

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(attachments) { attachment in
                    thumbnail(attachment)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .background(Color.gray.opacity(0.05))
    }
}
