import Foundation
import UIKit

/// Persistent disk cache for remote images (Google People API photos, etc.)
/// Survives app restarts, reducing network requests significantly.
actor DiskImageCache {
    static let shared = DiskImageCache()

    private nonisolated let cacheDirectory: URL
    private let fileManager = FileManager.default
    private let maxCacheAge: TimeInterval = 7 * 24 * 60 * 60 // 7 days
    private let maxCacheSize: Int64 = 100 * 1024 * 1024 // 100 MB

    // Track estimated cache size to avoid frequent disk scans
    private var estimatedCacheSize: Int64 = 0
    private var lastCleanupTime: Date = .distantPast
    private let cleanupInterval: TimeInterval = 300 // 5 minutes between cleanups

    /// Prevents concurrent cleanup operations from racing
    private var isCleaningUp = false

    /// Periodic cleanup task to ensure cleanup runs even when no new images are saved
    private var periodicCleanupTask: Task<Void, Never>?

    private init() {
        let cachesPath = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        self.cacheDirectory = cachesPath.appendingPathComponent("ImageCache")
        Self.createDirectoryIfNeeded(at: cacheDirectory)

        // Start periodic cleanup in a separate task to comply with Swift 6 actor init rules
        Task { await self.startPeriodicCleanup() }
    }

    /// Starts the periodic cleanup task - must be called from actor context
    private func startPeriodicCleanup() {
        periodicCleanupTask = Task { [weak self] in
            // Initial cleanup - measure actual size on startup to correct any drift
            await self?.performCleanupIfNotBusy()

            // Periodic cleanup every hour
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: 60 * 60 * 1_000_000_000) // 1 hour
                    await self?.performCleanupIfNotBusy()
                } catch {
                    // Task was cancelled
                    break
                }
            }
        }
    }

    /// Performs cleanup only if not already in progress, measuring actual disk size
    private func performCleanupIfNotBusy() async {
        guard !isCleaningUp else { return }
        isCleaningUp = true
        await cleanExpiredEntries()
        let size = totalSize()
        estimatedCacheSize = size
        isCleaningUp = false
    }

    deinit {
        periodicCleanupTask?.cancel()
    }

    private func updateEstimatedSize(_ size: Int64) {
        estimatedCacheSize = size
    }

    private static func createDirectoryIfNeeded(at directory: URL) {
        let fm = FileManager.default
        if !fm.fileExists(atPath: directory.path) {
            FileSystemErrorHandler.createDirectory(at: directory, category: .general)
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
        do {
            let attributes = try fileManager.attributesOfItem(atPath: fileURL.path)
            if let modDate = attributes[.modificationDate] as? Date,
               Date().timeIntervalSince(modDate) > maxCacheAge {
                FileSystemErrorHandler.removeItem(at: fileURL, category: .general)
                return nil
            }
        } catch {
            Log.debug("Failed to read cache file attributes: \(fileURL.lastPathComponent)", category: .general)
        }

        return FileSystemErrorHandler.loadData(from: fileURL, category: .general)
    }

    /// Gets cached image for a URL
    func getImage(for urlString: String) -> UIImage? {
        guard let data = getData(for: urlString) else { return nil }
        return UIImage(data: data)
    }

    /// Saves image data to cache
    func save(_ data: Data, for urlString: String) {
        let fileURL = cacheFileURL(for: urlString)
        FileSystemErrorHandler.writeData(data, to: fileURL, category: .general)

        // Update estimated size
        estimatedCacheSize += Int64(data.count)

        // Check if cleanup is needed (rate limited to avoid frequent disk scans)
        // Also prevent concurrent cleanups with isCleaningUp flag
        if estimatedCacheSize > maxCacheSize &&
           Date().timeIntervalSince(lastCleanupTime) > cleanupInterval &&
           !isCleaningUp {
            isCleaningUp = true
            lastCleanupTime = Date()
            Task.detached(priority: .utility) { [self] in
                await self.cleanExpiredEntries()
                // Update estimated size after cleanup (measure actual disk usage)
                let size = await self.totalSize()
                await self.updateEstimatedSize(size)
                await self.setCleaningUp(false)
            }
        }
    }

    private func setCleaningUp(_ value: Bool) {
        isCleaningUp = value
    }

    /// Saves UIImage to cache (as JPEG)
    func save(_ image: UIImage, for urlString: String, compressionQuality: CGFloat = 0.8) {
        guard let data = image.jpegData(compressionQuality: compressionQuality) else { return }
        save(data, for: urlString)
    }

    /// Removes cached image for URL
    func remove(for urlString: String) {
        let fileURL = cacheFileURL(for: urlString)
        FileSystemErrorHandler.removeItem(at: fileURL, category: .general)
    }

    /// Clears all cached images
    func clearAll() {
        FileSystemErrorHandler.removeItem(at: cacheDirectory, category: .general)
        Self.createDirectoryIfNeeded(at: cacheDirectory)
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
            FileSystemErrorHandler.removeItem(at: fileURL, category: .general)
        }

        // If still over size limit, delete oldest files
        if totalSize > maxCacheSize {
            let sortedFiles = fileInfos.sorted { $0.date < $1.date }
            var currentSize = totalSize

            for fileInfo in sortedFiles {
                if currentSize <= maxCacheSize {
                    break
                }
                FileSystemErrorHandler.removeItem(at: fileInfo.url, category: .general)
                currentSize -= fileInfo.size
            }
        }
    }
}
