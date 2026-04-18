import Foundation

/// Thread-safe HTML file storage operations.
/// Uses atomic writes and safe directory operations to prevent race conditions.
final class HTMLContentHandler {
    /// Shared singleton instance for efficient reuse across views
    static let shared = HTMLContentHandler()

    // Multiple services instantiate handlers, but they all read and write the same
    // on-disk Messages directory. Keep caches shared so saves and deletes stay coherent.
    private static let htmlContentCache: NSCache<NSString, NSString> = {
        let cache = NSCache<NSString, NSString>()
        cache.countLimit = 128
        cache.totalCostLimit = 15 * 1024 * 1024
        return cache
    }()

    private static let fileSignatureCache: NSCache<NSString, NSString> = {
        let cache = NSCache<NSString, NSString>()
        cache.countLimit = 1024
        return cache
    }()

    private let messagesDirectory: URL

    /// Serial queue for exclusive directory operations like deleteAllHTML
    private let exclusiveQueue = DispatchQueue(label: "com.esc.htmlcontent.exclusive")

    init() {
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        self.messagesDirectory = documentsPath.appendingPathComponent("Messages")
        createMessagesDirectoryIfNeeded()
    }

    private func createMessagesDirectoryIfNeeded() {
        if !FileManager.default.fileExists(atPath: messagesDirectory.path) {
            FileSystemErrorHandler.createDirectory(at: messagesDirectory, category: .general)
        }
    }

    /// Ensures the Messages directory exists. Call after cleanup operations that may delete it.
    func ensureDirectoryExists() {
        createMessagesDirectoryIfNeeded()
    }

    func saveHTML(_ html: String, for messageId: String) -> URL? {
        let fileURL = messagesDirectory.appendingPathComponent("\(messageId).html")

        do {
            try html.write(to: fileURL, atomically: true, encoding: .utf8)
            cacheHTML(html, for: fileURL)
            refreshSignatureCache(for: fileURL)
            return fileURL
        } catch {
            Log.error("Failed to save HTML for message \(messageId)", category: .general, error: error)
            return nil
        }
    }

    func loadHTML(from url: URL) -> String? {
        if let cached = cachedHTML(for: url) {
            return cached
        }

        guard FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }

        do {
            let html = try String(contentsOf: url, encoding: .utf8)
            cacheHTML(html, for: url)
            refreshSignatureCache(for: url)
            return html
        } catch {
            if isMissingFileError(error) {
                invalidateCaches(for: url)
                return nil
            }
            Log.error("Failed to load HTML from \(url)", category: .general, error: error)
            return nil
        }
    }

    func loadHTML(for messageId: String) -> String? {
        let fileURL = messagesDirectory.appendingPathComponent("\(messageId).html")
        return loadHTML(from: fileURL)
    }

    func deleteHTML(for messageId: String) {
        deleteHTML(for: messageId, bodyStorageURI: nil)
    }

    func deleteHTML(for messageId: String, bodyStorageURI: String?) {
        let fileURL = messagesDirectory.appendingPathComponent("\(messageId).html")
        FileSystemErrorHandler.removeItem(at: fileURL, category: .general)
        invalidateCaches(for: fileURL)

        guard let bodyStorageURI,
              let resolvedURL = StorageURIResolver.resolve(bodyStorageURI),
              resolvedURL.path != fileURL.path else {
            return
        }

        FileSystemErrorHandler.removeItem(at: resolvedURL, category: .general)
        invalidateCaches(for: resolvedURL)
    }

    func deleteAllHTML() {
        // Use exclusive queue to prevent concurrent deleteAllHTML operations
        // and prevent race conditions with concurrent reads
        exclusiveQueue.sync {
            // Delete contents instead of directory to avoid race conditions
            // This prevents other operations from failing when directory is temporarily missing
            let contents = FileSystemErrorHandler.contentsOfDirectory(at: messagesDirectory, category: .general)
            for fileURL in contents {
                FileSystemErrorHandler.removeItem(at: fileURL, category: .general)
            }
        }
        clearCaches()
    }

    func htmlFileExists(for messageId: String) -> Bool {
        let fileURL = messagesDirectory.appendingPathComponent("\(messageId).html")
        return cachedFileSignature(for: fileURL, cacheMissing: true) != "missing"
    }

    func htmlFileSignature(for messageId: String) -> String {
        let fileURL = messagesDirectory.appendingPathComponent("\(messageId).html")
        return cachedFileSignature(for: fileURL, cacheMissing: true)
    }

    func htmlSourceSignature(messageId: String, bodyStorageURI: String?) -> String {
        let primaryFileURL = messagesDirectory.appendingPathComponent("\(messageId).html")
        let primarySignature = cachedFileSignature(for: primaryFileURL, cacheMissing: true)
        if primarySignature != "missing" {
            return primarySignature
        }

        guard let bodyStorageURI,
              let resolvedURL = StorageURIResolver.resolve(bodyStorageURI),
              resolvedURL.path != primaryFileURL.path else {
            return primarySignature
        }

        return cachedFileSignature(for: resolvedURL, cacheMissing: false)
    }

    func calculateStorageSize() -> Int64 {
        var totalSize: Int64 = 0

        if let enumerator = FileManager.default.enumerator(at: messagesDirectory,
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

    func cleanupOldFiles(olderThan days: Int) {
        let cutoffDate = Date().addingTimeInterval(-Double(days * 24 * 60 * 60))

        if let enumerator = FileManager.default.enumerator(at: messagesDirectory,
                                                          includingPropertiesForKeys: [.creationDateKey],
                                                          options: [.skipsHiddenFiles]) {
            for case let fileURL as URL in enumerator {
                do {
                    let values = try fileURL.resourceValues(forKeys: [.creationDateKey])
                    if let creationDate = values.creationDate, creationDate < cutoffDate {
                        FileSystemErrorHandler.removeItem(at: fileURL, category: .general)
                        invalidateCaches(for: fileURL)
                    }
                } catch {
                    Log.debug("Failed to read creation date for \(fileURL.lastPathComponent)", category: .general)
                }
            }
        }
    }

    func cleanupOrphanedFiles(validMessageIds: Set<String>) {
        exclusiveQueue.sync {
            let contents = FileSystemErrorHandler.contentsOfDirectory(at: messagesDirectory, category: .general)
            for fileURL in contents {
                let messageId = fileURL.deletingPathExtension().lastPathComponent
                guard !messageId.isEmpty else { continue }
                if !validMessageIds.contains(messageId) {
                    FileSystemErrorHandler.removeItem(at: fileURL, category: .general)
                    invalidateCaches(for: fileURL)
                }
            }
        }
    }

    func migrateIfNeeded(from oldPath: String) -> Bool {
        // Check if the old path exists and the new one doesn't
        guard oldPath.contains("/Documents/Messages/"),
              let messageId = oldPath.components(separatedBy: "/").last?.replacingOccurrences(of: ".html", with: ""),
              !messageId.isEmpty else {
            return false
        }

        // Check if file already exists in current location
        if htmlFileExists(for: messageId) {
            return true // Already migrated
        }

        // Try to extract from old file URL if it exists
        if oldPath.starts(with: "file://") {
            if let url = URL(string: oldPath),
               FileManager.default.fileExists(atPath: url.path),
               let html = loadHTML(from: url) {
                // Save to new location
                return saveHTML(html, for: messageId) != nil
            }
        }

        return false
    }

    private func isMissingFileError(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain && nsError.code == NSFileReadNoSuchFileError {
            return true
        }

        return nsError.domain == NSPOSIXErrorDomain && nsError.code == ENOENT
    }

    private func cacheKey(for fileURL: URL) -> NSString {
        fileURL.standardizedFileURL.path as NSString
    }

    private func cachedHTML(for fileURL: URL) -> String? {
        guard let cached = Self.htmlContentCache.object(forKey: cacheKey(for: fileURL)) else {
            return nil
        }
        return String(cached)
    }

    private func cacheHTML(_ html: String, for fileURL: URL) {
        Self.htmlContentCache.setObject(
            html as NSString,
            forKey: cacheKey(for: fileURL),
            cost: html.utf8.count
        )
    }

    private func refreshSignatureCache(for fileURL: URL) {
        guard let signature = uncachedFileSignature(for: fileURL) else {
            invalidateSignatureCache(for: fileURL)
            return
        }

        Self.fileSignatureCache.setObject(signature as NSString, forKey: cacheKey(for: fileURL))
    }

    private func cachedFileSignature(for fileURL: URL, cacheMissing: Bool) -> String {
        let cacheKey = cacheKey(for: fileURL)
        if let cached = Self.fileSignatureCache.object(forKey: cacheKey) {
            return String(cached)
        }

        guard let signature = uncachedFileSignature(for: fileURL) else {
            if cacheMissing {
                Self.fileSignatureCache.setObject("missing" as NSString, forKey: cacheKey)
            }
            return "missing"
        }

        Self.fileSignatureCache.setObject(signature as NSString, forKey: cacheKey)
        return signature
    }

    private func uncachedFileSignature(for fileURL: URL) -> String? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return nil
        }

        let values = try? fileURL.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        let timestamp = values?.contentModificationDate?.timeIntervalSince1970 ?? 0
        let fileSize = values?.fileSize ?? 0
        return "\(timestamp)|\(fileSize)"
    }

    private func invalidateCaches(for fileURL: URL) {
        let cacheKey = cacheKey(for: fileURL)
        Self.htmlContentCache.removeObject(forKey: cacheKey)
        Self.fileSignatureCache.removeObject(forKey: cacheKey)
    }

    private func invalidateSignatureCache(for fileURL: URL) {
        Self.fileSignatureCache.removeObject(forKey: cacheKey(for: fileURL))
    }

    private func clearCaches() {
        Self.htmlContentCache.removeAllObjects()
        Self.fileSignatureCache.removeAllObjects()
    }
}
