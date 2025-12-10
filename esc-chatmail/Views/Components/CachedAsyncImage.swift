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

        // Handle HTTP URLs - use deduplicated loader
        await MainActor.run {
            isLoading = true
        }

        if let image = await ImageCache.shared.loadImage(from: urlString) {
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

    private func dataFromBase64URL(_ dataURL: String) -> Data? {
        guard let commaIndex = dataURL.firstIndex(of: ",") else { return nil }
        let base64String = String(dataURL[dataURL.index(after: commaIndex)...])
        return Data(base64Encoded: base64String)
    }
}

// MARK: - Image Cache

final class ImageCache: @unchecked Sendable {
    static let shared = ImageCache()

    private let cache = NSCache<NSString, UIImage>()
    private let requestManager = ImageRequestManager()

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

    /// Loads an image from URL with deduplication - multiple requests for the same URL
    /// will share a single network request
    func loadImage(from urlString: String) async -> UIImage? {
        // Check cache first
        if let cached = get(for: urlString) {
            return cached
        }

        // Use actor for thread-safe in-flight request management
        return await requestManager.loadImage(from: urlString) { [weak self] image in
            if let image = image {
                self?.set(image, for: urlString)
            }
        }
    }
}

// MARK: - Actor for In-Flight Request Deduplication

private actor ImageRequestManager {
    private var inFlightRequests: [String: Task<UIImage?, Never>] = [:]

    func loadImage(from urlString: String, onComplete: @escaping (UIImage?) -> Void) async -> UIImage? {
        // Check for existing in-flight request
        if let existingTask = inFlightRequests[urlString] {
            return await existingTask.value
        }

        // Create new task
        let task = Task<UIImage?, Never> {
            guard let url = URL(string: urlString) else { return nil }

            do {
                let (data, _) = try await URLSession.shared.data(from: url)
                if let image = UIImage(data: data) {
                    return image
                }
            } catch {
                print("Failed to load image: \(error.localizedDescription)")
            }
            return nil
        }

        inFlightRequests[urlString] = task

        let result = await task.value

        // Cache the result
        onComplete(result)

        // Clean up
        inFlightRequests.removeValue(forKey: urlString)

        return result
    }
}
