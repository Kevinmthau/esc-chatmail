import SwiftUI

/// Pure presentation of a grid cell's image layer: the loaded image on what it needs behind it, or
/// the placeholder. A loaded image with nothing to see in it takes the placeholder too, as it does
/// in `ImageAttachmentBubbleContent`.
struct AttachmentGridThumbnail: View {
    let image: PlatformImage?
    var backdrop: ImageBackdropPolicy = .none
    let isLoading: Bool
    let placeholderIconName: String
    let presentation: InlineImagePresentationPolicy
    /// The attachment's stored dimensions, which size a compact image.
    let pixelSize: CGSize
    let cellSize: CGSize
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        if let image = backdrop.visibleImage(image) {
            let card = backdrop.cardColor(for: presentation)
            if presentation == .compact {
                let size = InlineImagePresentationPolicy.fittedSize(
                    pixelWidth: pixelSize.width, pixelHeight: pixelSize.height,
                    maxWidth: max(0, cellSize.width - 16), displayScale: displayScale
                )
                Image(platformImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: size.width, height: min(size.height, max(0, cellSize.height - 16)))
                    .frame(width: cellSize.width, height: cellSize.height)
                    .background(card ?? .clear)
            } else {
                Image(platformImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: cellSize.width, height: cellSize.height)
                    .clipped()
                    .background(card ?? .clear)
            }
        } else {
            Rectangle()
                .fill(Color.gray.opacity(0.1))
                .overlay(
                    Group {
                        if isLoading {
                            ProgressView()
                                .progressViewStyle(CircularProgressViewStyle())
                                .scaleEffect(0.6)
                        } else {
                            Image(systemName: placeholderIconName)
                                .foregroundColor(.gray)
                        }
                    }
                )
        }
    }
}
