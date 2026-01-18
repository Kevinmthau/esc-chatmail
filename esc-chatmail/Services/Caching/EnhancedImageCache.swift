import Foundation
import UIKit

/// Two-tier image cache: fast memory cache backed by persistent disk cache
actor EnhancedImageCache: MemoryWarningHandler {
    static let shared = EnhancedImageCache()

    private let memoryCache = NSCache<NSString, UIImage>()
    private let diskCache = DiskImageCache.shared
    private let requestManager = ImageRequestManager()
    private let memoryObserver = MemoryWarningObserver()

    private init() {
        memoryCache.countLimit = 100
        memoryCache.totalCostLimit = 50 * 1024 * 1024 // 50 MB

        // Observe memory warnings
        Task { @MainActor [weak self] in
            guard let self = self else { return }
            self.memoryObserver.start(handler: self)
        }
    }

    // MARK: - MemoryWarningHandler

    func handleMemoryWarning() async {
        clearMemory()
    }

    /// Gets image from cache (memory first, then disk)
    func get(for key: String) async -> UIImage? {
        // Check memory cache (NSCache is thread-safe)
        if let cached = memoryCache.object(forKey: key as NSString) {
            return cached
        }

        // Check disk cache
        if let diskImage = await diskCache.getImage(for: key) {
            // Promote to memory cache
            memoryCache.setObject(diskImage, forKey: key as NSString)
            return diskImage
        }

        return nil
    }

    /// Sets image in both caches
    func set(_ image: UIImage, for key: String) async {
        memoryCache.setObject(image, forKey: key as NSString)

        // Save to disk
        await diskCache.save(image, for: key)
    }

    /// Clears memory cache only
    func clearMemory() {
        memoryCache.removeAllObjects()
    }

    /// Clears both memory and disk cache
    func clearAll() async {
        memoryCache.removeAllObjects()
        await diskCache.clearAll()
    }

    /// Loads an image from URL with deduplication and two-tier caching
    func loadImage(from urlString: String) async -> UIImage? {
        // Check caches first
        if let cached = await get(for: urlString) {
            return cached
        }

        // Handle file:// URLs (local avatars)
        if urlString.hasPrefix("file://") {
            if let data = await AvatarStorage.shared.loadAvatar(from: urlString),
               let image = UIImage(data: data) {
                memoryCache.setObject(image, forKey: urlString as NSString)
                return image
            }
            return nil
        }

        // Handle data:// URLs (legacy base64)
        if urlString.hasPrefix("data:image") {
            if let image = await ImageDecoder.decodeBase64Async(urlString) {
                memoryCache.setObject(image, forKey: urlString as NSString)
                return image
            }
            return nil
        }

        // Handle HTTP URLs - use actor for thread-safe deduplication
        return await requestManager.loadImage(from: urlString) { [self] image in
            if let image = image {
                Task {
                    await self.set(image, for: urlString)
                }
            }
        }
    }
}
