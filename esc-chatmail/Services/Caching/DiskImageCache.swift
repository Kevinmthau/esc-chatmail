import CryptoKit
import Foundation
import UIKit

/// Persistent disk cache for remote images (Google People API photos, etc.)
/// Survives app restarts, reducing network requests significantly.
actor DiskImageCache: PeriodicCleanupHandler {
    /// The production cache: owns `Caches/ImageCache` and sweeps it hourly.
    /// The `true` here is what keeps that directory bounded across relaunches
    /// (see `init`); nothing else schedules the sweep.
    static let shared = DiskImageCache(startsPeriodicCleanup: true)

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

    /// Periodic cleanup task helper
    private let cleanupTask = PeriodicCleanupTask()

    /// The directory and the sweep flag are testing seams; production code
    /// uses `shared`. The flag has no default because neither value is safe
    /// to assume. On, an injected instance is retained for the life of a task
    /// nothing cancels (`PeriodicCleanupTask` captures its handler) and its
    /// immediate first pass races a test still writing fixtures into the
    /// directory, whose own `performCleanup()` then returns early on
    /// `isCleaningUp`. Off, a production instance silently stops bounding its
    /// directory: `save()`'s size check fires only on an estimate that restarts
    /// at zero every launch, so without the hourly sweep the directory grows
    /// without limit across relaunches.
    init(cacheDirectory: URL? = nil, startsPeriodicCleanup: Bool) {
        if let cacheDirectory {
            self.cacheDirectory = cacheDirectory
        } else {
            let cachesPath = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory
            self.cacheDirectory = cachesPath.appendingPathComponent("ImageCache")
        }
        Self.createDirectoryIfNeeded(at: self.cacheDirectory)

        if startsPeriodicCleanup {
            // Start periodic cleanup in a separate task to comply with Swift 6 actor init rules
            Task { self.cleanupTask.start(handler: self, interval: .hours(1), runImmediately: true) }
        }
    }

    // MARK: - PeriodicCleanupHandler

    func performCleanup() async {
        guard !isCleaningUp else { return }
        isCleaningUp = true
        await cleanExpiredEntries()
        let size = totalSize()
        estimatedCacheSize = size
        isCleaningUp = false
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

    /// Gets cached image for a URL, decoded with a bounded bitmap size.
    /// Disk keeps the original bytes; only the decoded bitmap is capped
    /// (consumers render at most full-screen width, and the downsampled
    /// result being promoted to the memory cache is the desired behavior —
    /// it is what keeps the memory cache's cost accounting meaningful).
    func getImage(for urlString: String) -> UIImage? {
        guard let data = getData(for: urlString) else { return nil }
        return ImageDownsampler.decode(data: data)
    }

    /// Saves image data to cache
    func save(_ data: Data, for urlString: String) {
        let fileURL = cacheFileURL(for: urlString)
        FileSystemErrorHandler.writeData(data, to: fileURL, category: .general)

        // Update estimated size
        estimatedCacheSize += Int64(data.count)

        // Check if cleanup is needed (rate limited to avoid frequent disk scans)
        if estimatedCacheSize > maxCacheSize &&
           Date().timeIntervalSince(lastCleanupTime) > cleanupInterval &&
           !isCleaningUp {
            isCleaningUp = true
            lastCleanupTime = Date()
            // Run cleanup within the actor to prevent concurrent cleanup races
            Task {
                await cleanExpiredEntries()
                let size = totalSize()
                estimatedCacheSize = size
                isCleaningUp = false
            }
        }
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

    // MARK: - Filenames

    private static let cacheFileExtension = ".cache"

    /// CANONICAL mapping from an image URL to its cache filename: the SHA-256
    /// digest of the whole URL, so distinct URLs never share a file and the
    /// name is the same across launches. The scheme it replaced was the URL's
    /// base64 cut to 64 characters, which is only its first 48 bytes: every
    /// image behind one CDN path (a newsletter's entire image set) collapsed
    /// onto a single file, and once the memory tier no longer held them the
    /// first picture fetched was served for all of them — two different
    /// newsletters showing the same hero card. `isCurrentCacheFilename`
    /// recognizes this scheme so the sweep can drop the legacy files.
    static func cacheFilename(for urlString: String) -> String {
        let digest = SHA256.hash(data: Data(urlString.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return "\(hex)\(cacheFileExtension)"
    }

    /// True for a name `cacheFilename(for:)` can produce: 64 lowercase hex
    /// characters plus the cache extension. A legacy base64 name always carries
    /// an uppercase letter (every URL scheme encodes to one within its first
    /// characters), so none is mistaken for a current entry.
    static func isCurrentCacheFilename(_ filename: String) -> Bool {
        guard filename.hasSuffix(cacheFileExtension) else { return false }
        let stem = filename.dropLast(cacheFileExtension.count)
        return stem.count == 64 && stem.allSatisfy { $0.isASCII && $0.isHexDigit && !$0.isUppercase }
    }

    // MARK: - Private Helpers

    private func cacheFileURL(for urlString: String) -> URL {
        cacheDirectory.appendingPathComponent(Self.cacheFilename(for: urlString))
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
            includingPropertiesForKeys: [.contentAccessDateKey, .contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        var filesToDelete: [URL] = []
        var totalSize: Int64 = 0
        var fileInfos: [(url: URL, date: Date, size: Int64)] = []

        while let fileURL = enumerator.nextObject() as? URL {
            // A legacy base64-named entry (see `cacheFilename(for:)`) is never
            // read again, so reclaim it now instead of after its 7-day age-out;
            // it may hold the wrong picture for every URL that shared its prefix.
            guard Self.isCurrentCacheFilename(fileURL.lastPathComponent) else {
                filesToDelete.append(fileURL)
                continue
            }

            guard let values = try? fileURL.resourceValues(forKeys: [.contentAccessDateKey, .contentModificationDateKey, .fileSizeKey]),
                  let fileSize = values.fileSize else {
                continue
            }

            // Use access date for LRU eviction, fall back to modification date
            let accessDate = values.contentAccessDate ?? values.contentModificationDate ?? .distantPast
            let age = Date().timeIntervalSince(accessDate)

            if age > maxCacheAge {
                filesToDelete.append(fileURL)
            } else {
                totalSize += Int64(fileSize)
                fileInfos.append((fileURL, accessDate, Int64(fileSize)))
            }
        }

        // Delete expired files
        for fileURL in filesToDelete {
            FileSystemErrorHandler.removeItem(at: fileURL, category: .general)
        }

        // If still over size limit, delete least-recently-accessed files
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
