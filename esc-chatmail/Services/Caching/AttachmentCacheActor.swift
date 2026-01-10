import UIKit

/// Thread-safe actor-based cache for attachment images and data.
/// Uses LRUCacheActor internally for proper concurrency.
actor AttachmentCacheActor {
    static let shared = AttachmentCacheActor()

    // MARK: - Cache Instances

    private let thumbnailCache: LRUCacheActor<String, UIImage>
    private let fullImageCache: LRUCacheActor<String, UIImage>
    private let dataCache: LRUCacheActor<String, Data>
    private let requestManager = InFlightRequestManager<String, UIImage>()
    private var memoryWarningObserver: (any NSObjectProtocol)?

    // MARK: - Initialization

    init() {
        // Thumbnail cache: ~50MB (assuming ~100KB per thumbnail)
        self.thumbnailCache = LRUCacheActor(config: CacheConfiguration(
            maxItems: 500,
            maxMemoryBytes: 50 * 1024 * 1024,
            ttlSeconds: nil,
            evictionPolicy: .lru
        ))

        // Full image cache: ~100MB (for viewing)
        self.fullImageCache = LRUCacheActor(config: CacheConfiguration(
            maxItems: 20,
            maxMemoryBytes: 100 * 1024 * 1024,
            ttlSeconds: nil,
            evictionPolicy: .lru
        ))

        // Data cache: ~25MB (for quick access to raw data)
        self.dataCache = LRUCacheActor(config: CacheConfiguration(
            maxItems: 50,
            maxMemoryBytes: 25 * 1024 * 1024,
            ttlSeconds: nil,
            evictionPolicy: .lru
        ))

        // Observe memory warnings on the main actor
        Task { @MainActor [weak self] in
            let observer = NotificationCenter.default.addObserver(
                forName: UIApplication.didReceiveMemoryWarningNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task {
                    await self?.clearCache(level: .aggressive)
                }
            }
            await self?.setMemoryWarningObserver(observer)
        }
    }

    private func setMemoryWarningObserver(_ observer: any NSObjectProtocol) {
        memoryWarningObserver = observer
    }

    deinit {
        if let observer = memoryWarningObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    // MARK: - Cache Clear Levels

    enum CacheClearLevel {
        case light      // Clear full images only
        case moderate   // Clear full images and data
        case aggressive // Clear everything
    }

    func clearCache(level: CacheClearLevel = .moderate) async {
        switch level {
        case .light:
            await fullImageCache.clear()
        case .moderate:
            await fullImageCache.clear()
            await dataCache.clear()
        case .aggressive:
            await fullImageCache.clear()
            await dataCache.clear()
            await thumbnailCache.clear()
            await requestManager.clearFailedKeys()
        }
    }

    // MARK: - Thumbnail Loading

    func loadThumbnail(for attachmentId: String, from path: String?) async -> UIImage? {
        let cacheKey = "thumb_\(attachmentId)"

        // Check memory cache
        if let cached = await thumbnailCache.get(cacheKey) {
            return cached
        }

        // Use request manager for deduplication
        let result = await requestManager.deduplicated(key: cacheKey) {
            // Load from disk
            guard let path = path,
                  let data = AttachmentPaths.loadData(from: path) else {
                return nil
            }

            // Decode image
            return UIImage(data: data)
        }

        // Cache the result
        if let image = result {
            let cost = image.jpegData(compressionQuality: 0.8)?.count ?? 0
            await thumbnailCache.set(cacheKey, value: image, sizeBytes: cost)
        }

        return result
    }

    // MARK: - Downsampled Image Loading

    func loadDownsampledImage(
        for attachmentId: String,
        from path: String?,
        targetSize: CGSize,
        contentMode: UIView.ContentMode = .scaleAspectFill
    ) async -> UIImage? {
        let cacheKey = "downsampled_\(attachmentId)_\(Int(targetSize.width))x\(Int(targetSize.height))"

        // Check memory cache
        if let cached = await fullImageCache.get(cacheKey) {
            return cached
        }

        // Load and downsample
        guard let path = path,
              let url = AttachmentPaths.fullURL(for: path) else {
            return nil
        }

        // Capture screen scale on main actor before detached task
        let scale = await MainActor.run { UIScreen.main.scale }

        let image = await Task.detached(priority: .userInitiated) {
            self.downsampleImage(at: url, to: targetSize, contentMode: contentMode, scale: scale)
        }.value

        // Cache the downsampled image
        if let image = image {
            let cost = Int(targetSize.width * targetSize.height * 4)
            await fullImageCache.set(cacheKey, value: image, sizeBytes: cost)
        }

        return image
    }

    private nonisolated func downsampleImage(
        at url: URL,
        to targetSize: CGSize,
        contentMode: UIView.ContentMode,
        scale: CGFloat
    ) -> UIImage? {
        let imageSourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let imageSource = CGImageSourceCreateWithURL(url as CFURL, imageSourceOptions) else {
            return nil
        }

        let maxDimensionInPixels = max(targetSize.width, targetSize.height) * scale
        let downsampleOptions = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxDimensionInPixels
        ] as CFDictionary

        guard let downsampledImage = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, downsampleOptions) else {
            return nil
        }

        return UIImage(cgImage: downsampledImage)
    }

    // MARK: - Full Image Loading

    func loadFullImage(for attachmentId: String, from path: String?) async -> UIImage? {
        let cacheKey = "full_\(attachmentId)"

        // Check memory cache
        if let cached = await fullImageCache.get(cacheKey) {
            return cached
        }

        // Load from disk with size limit
        guard let path = path,
              let url = AttachmentPaths.fullURL(for: path) else {
            return nil
        }

        // Capture screen scale on main actor before detached task
        let scale = await MainActor.run { UIScreen.main.scale }

        let image = await Task.detached(priority: .userInitiated) {
            // Use downsampling for very large images
            let maxDimension: CGFloat = 4096
            let targetSize = CGSize(width: maxDimension, height: maxDimension)
            return self.loadImageWithSizeLimit(at: url, maxSize: targetSize, scale: scale)
        }.value

        // Cache with estimated cost
        if let image = image {
            let cost = Int(image.size.width * image.size.height * 4 * image.scale * image.scale)
            await fullImageCache.set(cacheKey, value: image, sizeBytes: cost)
        }

        return image
    }

    private nonisolated func loadImageWithSizeLimit(at url: URL, maxSize: CGSize, scale: CGFloat) -> UIImage? {
        // First, get image dimensions without loading the full image
        let imageSourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let imageSource = CGImageSourceCreateWithURL(url as CFURL, imageSourceOptions),
              let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? CGFloat,
              let height = properties[kCGImagePropertyPixelHeight] as? CGFloat else {
            return nil
        }

        // If image is small enough, load it directly
        if width <= maxSize.width && height <= maxSize.height {
            return UIImage(contentsOfFile: url.path)
        }

        // Otherwise, downsample it
        return downsampleImage(at: url, to: maxSize, contentMode: .scaleAspectFit, scale: scale)
    }

    // MARK: - Data Cache

    func cacheData(_ data: Data, for key: String) async {
        await dataCache.set(key, value: data, sizeBytes: data.count)
    }

    func getCachedData(for key: String) async -> Data? {
        await dataCache.get(key)
    }

    // MARK: - Preloading

    nonisolated func preloadThumbnails(for attachmentIds: [(id: String, path: String?)]) {
        Task {
            await withTaskGroup(of: Void.self) { group in
                for (id, path) in attachmentIds.prefix(10) { // Limit concurrent preloads
                    group.addTask {
                        _ = await self.loadThumbnail(for: id, from: path)
                    }
                }
            }
        }
    }
}
