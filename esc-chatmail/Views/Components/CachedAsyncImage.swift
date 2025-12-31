import SwiftUI

/// A cached async image loader that supports both Data and URL sources
struct CachedAsyncImage: View {
    let imageData: Data?
    let imageURL: String?
    let size: CGFloat
    let placeholder: AnyView

    @State private var loadedImage: UIImage?
    @State private var isLoading = false

    init(
        imageData: Data? = nil,
        imageURL: String? = nil,
        size: CGFloat,
        @ViewBuilder placeholder: () -> some View
    ) {
        self.imageData = imageData
        self.imageURL = imageURL
        self.size = size
        self.placeholder = AnyView(placeholder())
    }

    var body: some View {
        Group {
            if let image = loadedImage {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: size, height: size)
                    .clipShape(Circle())
            } else if isLoading {
                ProgressView()
                    .frame(width: size, height: size)
            } else {
                placeholder
            }
        }
        .task {
            await loadImage()
        }
    }

    private func loadImage() async {
        // Try imageData first (decode on background thread)
        if let data = imageData {
            if let image = await ImageDecoder.decodeAsync(data) {
                await MainActor.run {
                    loadedImage = image
                }
                return
            }
        }

        // Try URL
        guard let urlString = imageURL, !urlString.isEmpty else { return }

        await MainActor.run {
            isLoading = true
        }

        // Use enhanced cache (handles data URLs, file URLs, and HTTP URLs with disk caching)
        if let image = await EnhancedImageCache.shared.loadImage(from: urlString) {
            await MainActor.run {
                loadedImage = image
                isLoading = false
            }
        } else {
            await MainActor.run {
                isLoading = false
            }
        }
    }
}

// MARK: - Legacy ImageCache (forwards to EnhancedImageCache)

/// Backwards-compatible wrapper - use EnhancedImageCache directly for new code
final class ImageCache: Sendable {
    static let shared = ImageCache()

    private init() {}

    func get(for key: String) -> UIImage? {
        EnhancedImageCache.shared.get(for: key)
    }

    func set(_ image: UIImage, for key: String) {
        EnhancedImageCache.shared.set(image, for: key)
    }

    func clear() {
        EnhancedImageCache.shared.clearMemory()
    }

    func loadImage(from urlString: String) async -> UIImage? {
        await EnhancedImageCache.shared.loadImage(from: urlString)
    }
}
