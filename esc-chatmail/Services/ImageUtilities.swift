import Foundation
import UIKit

// MARK: - Base64 Image Decoding (Consolidated)

/// Centralized utilities for image decoding - eliminates duplicate code across views
enum ImageDecoder {
    /// Decodes a base64 data URL to UIImage. Thread-safe, can be called from any thread.
    static func decodeBase64DataURL(_ dataURL: String) -> UIImage? {
        guard dataURL.hasPrefix("data:image"),
              let commaIndex = dataURL.firstIndex(of: ",") else {
            return nil
        }
        let base64String = String(dataURL[dataURL.index(after: commaIndex)...])
        guard let data = Data(base64Encoded: base64String) else { return nil }
        return UIImage(data: data)
    }

    /// Decodes image data on a background thread
    static func decodeAsync(_ data: Data) async -> UIImage? {
        await Task.detached(priority: .userInitiated) {
            UIImage(data: data)
        }.value
    }

    /// Decodes a base64 data URL on a background thread
    static func decodeBase64Async(_ dataURL: String) async -> UIImage? {
        await Task.detached(priority: .userInitiated) {
            decodeBase64DataURL(dataURL)
        }.value
    }
}

// MARK: - Disk Image Cache

/// Persistent disk cache for remote images (Google People API photos, etc.)
/// Survives app restarts, reducing network requests significantly.
final class DiskImageCache: @unchecked Sendable {
    static let shared = DiskImageCache()

    private let cacheDirectory: URL
    private let fileManager = FileManager.default
    private let maxCacheAge: TimeInterval = 7 * 24 * 60 * 60 // 7 days
    private let maxCacheSize: Int64 = 100 * 1024 * 1024 // 100 MB

    private init() {
        let cachesPath = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first!
        self.cacheDirectory = cachesPath.appendingPathComponent("ImageCache")
        createDirectoryIfNeeded()

        // Clean old entries on init (in background)
        Task.detached(priority: .utility) {
            await self.cleanExpiredEntries()
        }
    }

    private func createDirectoryIfNeeded() {
        if !fileManager.fileExists(atPath: cacheDirectory.path) {
            try? fileManager.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        }
    }

    // MARK: - Public API

    /// Gets cached image data for a URL
    func getData(for urlString: String) -> Data? {
        let fileURL = cacheFileURL(for: urlString)

        guard fileManager.fileExists(atPath: fileURL.path) else {
            return nil
        }

        // Check if expired
        if let attributes = try? fileManager.attributesOfItem(atPath: fileURL.path),
           let modDate = attributes[.modificationDate] as? Date,
           Date().timeIntervalSince(modDate) > maxCacheAge {
            try? fileManager.removeItem(at: fileURL)
            return nil
        }

        return try? Data(contentsOf: fileURL)
    }

    /// Gets cached image for a URL
    func getImage(for urlString: String) -> UIImage? {
        guard let data = getData(for: urlString) else { return nil }
        return UIImage(data: data)
    }

    /// Saves image data to cache
    func save(_ data: Data, for urlString: String) {
        let fileURL = cacheFileURL(for: urlString)
        try? data.write(to: fileURL, options: .atomic)
    }

    /// Saves UIImage to cache (as JPEG)
    func save(_ image: UIImage, for urlString: String, compressionQuality: CGFloat = 0.8) {
        guard let data = image.jpegData(compressionQuality: compressionQuality) else { return }
        save(data, for: urlString)
    }

    /// Removes cached image for URL
    func remove(for urlString: String) {
        let fileURL = cacheFileURL(for: urlString)
        try? fileManager.removeItem(at: fileURL)
    }

    /// Clears all cached images
    func clearAll() {
        try? fileManager.removeItem(at: cacheDirectory)
        createDirectoryIfNeeded()
    }

    /// Returns total cache size in bytes
    func totalSize() -> Int64 {
        var totalSize: Int64 = 0

        if let enumerator = fileManager.enumerator(at: cacheDirectory,
                                                   includingPropertiesForKeys: [.fileSizeKey],
                                                   options: [.skipsHiddenFiles]) {
            for case let fileURL as URL in enumerator {
                if let fileSize = try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                    totalSize += Int64(fileSize)
                }
            }
        }

        return totalSize
    }

    // MARK: - Private Helpers

    private func cacheFileURL(for urlString: String) -> URL {
        let hash = urlString.data(using: .utf8)?.base64EncodedString()
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "+", with: "-")
            .prefix(64) ?? "unknown"
        return cacheDirectory.appendingPathComponent("\(hash).cache")
    }

    private func cleanExpiredEntries() async {
        // Perform file system operations synchronously to avoid Swift 6 async iteration issues
        let cacheDir = cacheDirectory
        let maxAge = maxCacheAge
        let maxSize = maxCacheSize
        let fm = fileManager

        await Task.detached(priority: .utility) {
            Self.performCleanup(cacheDirectory: cacheDir, maxCacheAge: maxAge, maxCacheSize: maxSize, fileManager: fm)
        }.value
    }

    /// Synchronous cleanup helper - avoids async iteration issues with FileManager enumerator
    private static func performCleanup(cacheDirectory: URL, maxCacheAge: TimeInterval, maxCacheSize: Int64, fileManager: FileManager) {
        guard let enumerator = fileManager.enumerator(
            at: cacheDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        var filesToDelete: [URL] = []
        var totalSize: Int64 = 0
        var fileInfos: [(url: URL, date: Date, size: Int64)] = []

        while let fileURL = enumerator.nextObject() as? URL {
            guard let values = try? fileURL.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
                  let modDate = values.contentModificationDate,
                  let fileSize = values.fileSize else {
                continue
            }

            let age = Date().timeIntervalSince(modDate)

            if age > maxCacheAge {
                filesToDelete.append(fileURL)
            } else {
                totalSize += Int64(fileSize)
                fileInfos.append((fileURL, modDate, Int64(fileSize)))
            }
        }

        // Delete expired files
        for fileURL in filesToDelete {
            try? fileManager.removeItem(at: fileURL)
        }

        // If still over size limit, delete oldest files
        if totalSize > maxCacheSize {
            let sortedFiles = fileInfos.sorted { $0.date < $1.date }
            var currentSize = totalSize

            for fileInfo in sortedFiles {
                if currentSize <= maxCacheSize {
                    break
                }
                try? fileManager.removeItem(at: fileInfo.url)
                currentSize -= fileInfo.size
            }
        }
    }
}

// MARK: - Enhanced Image Cache (Memory + Disk)

/// Two-tier image cache: fast memory cache backed by persistent disk cache
final class EnhancedImageCache: @unchecked Sendable {
    static let shared = EnhancedImageCache()

    private let memoryCache = NSCache<NSString, UIImage>()
    private let diskCache = DiskImageCache.shared
    private let requestManager = ImageRequestManager()

    private init() {
        memoryCache.countLimit = 100
        memoryCache.totalCostLimit = 50 * 1024 * 1024 // 50 MB
    }

    /// Gets image from cache (memory first, then disk)
    func get(for key: String) -> UIImage? {
        // Check memory cache
        if let cached = memoryCache.object(forKey: key as NSString) {
            return cached
        }

        // Check disk cache
        if let diskImage = diskCache.getImage(for: key) {
            // Promote to memory cache
            memoryCache.setObject(diskImage, forKey: key as NSString)
            return diskImage
        }

        return nil
    }

    /// Sets image in both caches
    func set(_ image: UIImage, for key: String) {
        memoryCache.setObject(image, forKey: key as NSString)

        // Save to disk in background
        Task.detached(priority: .utility) {
            self.diskCache.save(image, for: key)
        }
    }

    /// Clears memory cache only
    func clearMemory() {
        memoryCache.removeAllObjects()
    }

    /// Clears both memory and disk cache
    func clearAll() {
        memoryCache.removeAllObjects()
        diskCache.clearAll()
    }

    /// Loads an image from URL with deduplication and two-tier caching
    func loadImage(from urlString: String) async -> UIImage? {
        // Check caches first
        if let cached = get(for: urlString) {
            return cached
        }

        // Handle file:// URLs (local avatars)
        if urlString.hasPrefix("file://") {
            if let data = AvatarStorage.shared.loadAvatar(from: urlString),
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
