import SwiftUI

/// Displays an avatar in message bubbles with support for:
/// - Contact image data
/// - Remote avatar URLs (from Google People API)
/// - Initials fallback
struct BubbleAvatarView: View {
    let name: String
    let avatarURL: String?
    let imageData: Data?

    @State private var loadedImage: UIImage?
    /// Tracks the URL we're currently loading to prevent stale updates during cell reuse
    @State private var loadingAvatarURL: String?

    private var displayImage: UIImage? {
        // Priority: contact image data > loaded URL image
        if let data = imageData, let image = UIImage(data: data) {
            return image
        }
        return loadedImage
    }

    var body: some View {
        Group {
            if let image = displayImage {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 24, height: 24)
                    .clipShape(Circle())
            } else {
                InitialsAvatarView(name: name, style: .bubble)
            }
        }
        .task(id: avatarURL) {
            // Reset loaded image when avatar URL changes (cell reuse)
            loadedImage = nil
            await loadAvatarIfNeeded()
        }
    }

    private func loadAvatarIfNeeded() async {
        // Only load from URL if no contact image data
        guard imageData == nil else { return }
        guard let urlString = avatarURL, !urlString.isEmpty else { return }

        // Track which URL we're loading to prevent stale updates during cell reuse
        loadingAvatarURL = urlString

        if let image = await EnhancedImageCache.shared.loadImage(from: urlString) {
            // Only update if we're still loading the same URL (cell wasn't reused)
            guard loadingAvatarURL == urlString else { return }
            loadedImage = image
        }
    }
}
