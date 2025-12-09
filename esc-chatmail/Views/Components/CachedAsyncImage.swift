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
        // Try imageData first
        if let data = imageData, let image = UIImage(data: data) {
            await MainActor.run {
                loadedImage = image
            }
            return
        }

        // Try URL
        guard let urlString = imageURL, !urlString.isEmpty else { return }

        // Handle data URLs
        if urlString.hasPrefix("data:image") {
            if let data = dataFromBase64URL(urlString), let image = UIImage(data: data) {
                await MainActor.run {
                    loadedImage = image
                }
            }
            return
        }

        // Handle HTTP URLs
        guard let url = URL(string: urlString) else { return }

        await MainActor.run {
            isLoading = true
        }

        do {
            // Check image cache first
            if let cachedImage = ImageCache.shared.get(for: urlString) {
                await MainActor.run {
                    loadedImage = cachedImage
                    isLoading = false
                }
                return
            }

            let (data, _) = try await URLSession.shared.data(from: url)
            if let image = UIImage(data: data) {
                // Cache the image
                ImageCache.shared.set(image, for: urlString)

                await MainActor.run {
                    loadedImage = image
                    isLoading = false
                }
            }
        } catch {
            print("Failed to load image from URL: \(error)")
            await MainActor.run {
                isLoading = false
            }
        }
    }

    private func dataFromBase64URL(_ dataURL: String) -> Data? {
        guard let commaIndex = dataURL.firstIndex(of: ",") else { return nil }
        let base64String = String(dataURL[dataURL.index(after: commaIndex)...])
        return Data(base64Encoded: base64String)
    }
}

// MARK: - Image Cache

final class ImageCache {
    static let shared = ImageCache()

    private let cache = NSCache<NSString, UIImage>()

    private init() {
        cache.countLimit = 100
        cache.totalCostLimit = 50 * 1024 * 1024 // 50 MB
    }

    func get(for key: String) -> UIImage? {
        cache.object(forKey: key as NSString)
    }

    func set(_ image: UIImage, for key: String) {
        cache.setObject(image, forKey: key as NSString)
    }

    func remove(for key: String) {
        cache.removeObject(forKey: key as NSString)
    }

    func clear() {
        cache.removeAllObjects()
    }
}
