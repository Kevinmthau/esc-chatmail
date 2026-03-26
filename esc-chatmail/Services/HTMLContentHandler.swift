import Foundation

/// Thread-safe HTML file storage operations.
/// Uses atomic writes and safe directory operations to prevent race conditions.
final class HTMLContentHandler {
    /// Shared singleton instance for efficient reuse across views
    static let shared = HTMLContentHandler()

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
            return fileURL
        } catch {
            Log.error("Failed to save HTML for message \(messageId)", category: .general, error: error)
            return nil
        }
    }

    func loadHTML(from url: URL) -> String? {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }

        do {
            return try String(contentsOf: url, encoding: .utf8)
        } catch {
            if isMissingFileError(error) {
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

        guard let bodyStorageURI,
              let resolvedURL = StorageURIResolver.resolve(bodyStorageURI),
              resolvedURL.path != fileURL.path else {
            return
        }

        FileSystemErrorHandler.removeItem(at: resolvedURL, category: .general)
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
    }

    func htmlFileExists(for messageId: String) -> Bool {
        let fileURL = messagesDirectory.appendingPathComponent("\(messageId).html")
        return FileManager.default.fileExists(atPath: fileURL.path)
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
}
