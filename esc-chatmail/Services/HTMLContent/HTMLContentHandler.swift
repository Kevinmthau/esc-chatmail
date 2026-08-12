import Foundation

/// Identifies the account-storage generation observed before asynchronous HTML
/// work begins. A token from an older account is rejected even after storage is
/// reopened for a new login.
struct HTMLContentAccountGeneration: Hashable, Sendable {
    fileprivate let directoryKey: String
    fileprivate let value: UInt64
}

/// Serializes every reader/writer that targets the same Messages directory and
/// provides a process-wide close/reopen generation boundary across the many
/// `HTMLContentHandler` instances used by loaders and persistence services.
private final class HTMLContentAccountBoundary: @unchecked Sendable {
    private let lock = NSRecursiveLock()
    private var acceptsWork = true
    private var generation: UInt64 = 0

    func capture(directoryKey: String) -> HTMLContentAccountGeneration? {
        lock.lock()
        defer { lock.unlock() }
        guard acceptsWork else { return nil }
        return HTMLContentAccountGeneration(directoryKey: directoryKey, value: generation)
    }

    func isCurrent(_ token: HTMLContentAccountGeneration, directoryKey: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return acceptsWork && token.directoryKey == directoryKey && token.value == generation
    }

    func perform<T>(
        directoryKey: String,
        expectedGeneration: HTMLContentAccountGeneration?,
        _ operation: () throws -> T
    ) rethrows -> T? {
        lock.lock()
        defer { lock.unlock() }
        guard acceptsWork else { return nil }
        if let expectedGeneration {
            guard expectedGeneration.directoryKey == directoryKey,
                  expectedGeneration.value == generation else {
                return nil
            }
        }
        return try operation()
    }

    func closeAndPerform(_ operation: () -> Void) {
        lock.lock()
        defer { lock.unlock() }
        acceptsWork = false
        generation &+= 1
        operation()
    }

    func reopen(afterPreparing operation: () throws -> Void) throws {
        lock.lock()
        defer { lock.unlock() }
        try operation()
        generation &+= 1
        acceptsWork = true
    }
}

private enum HTMLContentAccountBoundaryRegistry {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var boundaries: [String: HTMLContentAccountBoundary] = [:]

    static func boundary(for directoryKey: String) -> HTMLContentAccountBoundary {
        lock.lock()
        defer { lock.unlock() }
        if let existing = boundaries[directoryKey] {
            return existing
        }
        let boundary = HTMLContentAccountBoundary()
        boundaries[directoryKey] = boundary
        return boundary
    }
}

/// Thread-safe HTML file storage operations.
/// Uses atomic writes and safe directory operations to prevent race conditions.
final class HTMLContentHandler: @unchecked Sendable {
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
    private let directoryKey: String
    private let accountBoundary: HTMLContentAccountBoundary
    private let deleteHTMLFiles: @Sendable (URL) throws -> Void

    init(
        messagesDirectory: URL? = nil,
        deleteHTMLFiles: (@Sendable (URL) throws -> Void)? = nil
    ) {
        if let messagesDirectory {
            self.messagesDirectory = messagesDirectory
        } else {
            let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory
            self.messagesDirectory = documentsPath.appendingPathComponent("Messages")
        }
        self.directoryKey = self.messagesDirectory.standardizedFileURL.path
        self.accountBoundary = HTMLContentAccountBoundaryRegistry.boundary(for: self.directoryKey)
        self.deleteHTMLFiles = deleteHTMLFiles ?? { directory in
            guard FileManager.default.fileExists(atPath: directory.path) else {
                return
            }
            let contents = try FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil
            )
            for fileURL in contents {
                try FileManager.default.removeItem(at: fileURL)
            }
        }
        createMessagesDirectoryIfNeeded()
    }

    private func createMessagesDirectoryIfNeeded() {
        _ = accountBoundary.perform(directoryKey: directoryKey, expectedGeneration: nil) {
            if !FileManager.default.fileExists(atPath: messagesDirectory.path) {
                FileSystemErrorHandler.createDirectory(at: messagesDirectory, category: .general)
            }
        }
    }

    /// Ensures the Messages directory exists. Call after cleanup operations that may delete it.
    func ensureDirectoryExists() {
        createMessagesDirectoryIfNeeded()
    }

    /// Reports whether canonical message HTML survived without a corresponding
    /// account row, as can happen after sign-out on an older app version.
    func hasStoredHTMLFiles() throws -> Bool {
        try accountBoundary.perform(
            directoryKey: directoryKey,
            expectedGeneration: nil
        ) {
            do {
                let contents = try FileManager.default.contentsOfDirectory(
                    at: messagesDirectory,
                    includingPropertiesForKeys: nil
                )
                return !contents.isEmpty
            } catch let error as CocoaError
                where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
                return false
            } catch {
                // Protection, permission, and I/O failures do not prove that
                // another account's canonical HTML is absent.
                throw error
            }
        } ?? true
    }

    func captureAccountGeneration() -> HTMLContentAccountGeneration? {
        accountBoundary.capture(directoryKey: directoryKey)
    }

    func isAccountGenerationCurrent(_ generation: HTMLContentAccountGeneration) -> Bool {
        accountBoundary.isCurrent(generation, directoryKey: directoryKey)
    }

    /// Closes admission and waits for every synchronized file/cache operation
    /// already in progress. This synchronous boundary must be established before
    /// starting the potentially expensive filesystem cleanup.
    func closeAccountWork() {
        accountBoundary.closeAndPerform {
            clearCaches()
        }
    }

    /// Removes canonical HTML after `closeAccountWork()` has rejected all new
    /// readers and writers. Await completion before reopening account work.
    func deleteAllHTMLFromClosedAccount() async throws {
        let messagesDirectory = messagesDirectory
        let deleteHTMLFiles = deleteHTMLFiles
        try await Task.detached(priority: .utility) {
            try deleteHTMLFiles(messagesDirectory)
        }.value
    }

    func reopenAccountWork() throws {
        try accountBoundary.reopen(afterPreparing: {
            try FileManager.default.createDirectory(
                at: messagesDirectory,
                withIntermediateDirectories: true
            )
            clearCaches()
        })
    }

    func saveHTML(_ html: String, for messageId: String) -> URL? {
        saveHTML(html, for: messageId, expectedGeneration: nil)
    }

    func saveHTML(
        _ html: String,
        for messageId: String,
        expectedGeneration: HTMLContentAccountGeneration?
    ) -> URL? {
        let fileURL = messagesDirectory.appendingPathComponent("\(messageId).html")

        do {
            return try accountBoundary.perform(
                directoryKey: directoryKey,
                expectedGeneration: expectedGeneration
            ) {
                try html.write(to: fileURL, atomically: true, encoding: .utf8)
                cacheHTML(html, for: fileURL)
                refreshSignatureCache(for: fileURL)
                return fileURL
            }
        } catch {
            Log.error("Failed to save HTML for message \(messageId)", category: .general, error: error)
            return nil
        }
    }

    func loadHTML(from url: URL) -> String? {
        loadHTML(from: url, expectedGeneration: nil)
    }

    func loadHTML(
        from url: URL,
        expectedGeneration: HTMLContentAccountGeneration?
    ) -> String? {
        accountBoundary.perform(
            directoryKey: directoryKey,
            expectedGeneration: expectedGeneration
        ) {
            loadHTMLWithoutBoundary(from: url)
        } ?? nil
    }

    private func loadHTMLWithoutBoundary(from url: URL) -> String? {
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
        loadHTML(for: messageId, expectedGeneration: nil)
    }

    func loadHTML(
        for messageId: String,
        expectedGeneration: HTMLContentAccountGeneration?
    ) -> String? {
        let fileURL = messagesDirectory.appendingPathComponent("\(messageId).html")
        return loadHTML(from: fileURL, expectedGeneration: expectedGeneration)
    }

    func deleteHTML(for messageId: String) {
        deleteHTML(for: messageId, bodyStorageURI: nil)
    }

    func deleteHTML(
        for messageId: String,
        bodyStorageURI: String?,
        expectedGeneration: HTMLContentAccountGeneration? = nil
    ) {
        _ = accountBoundary.perform(
            directoryKey: directoryKey,
            expectedGeneration: expectedGeneration
        ) {
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
    }

    func deleteAllHTML() {
        _ = accountBoundary.perform(directoryKey: directoryKey, expectedGeneration: nil) {
            // Delete contents instead of directory to avoid race conditions
            // This prevents other operations from failing when directory is temporarily missing
            let contents = FileSystemErrorHandler.contentsOfDirectory(at: messagesDirectory, category: .general)
            for fileURL in contents {
                FileSystemErrorHandler.removeItem(at: fileURL, category: .general)
            }
            clearCaches()
        }
    }

    func htmlFileExists(for messageId: String) -> Bool {
        htmlFileExists(for: messageId, expectedGeneration: nil)
    }

    func htmlFileExists(
        for messageId: String,
        expectedGeneration: HTMLContentAccountGeneration?
    ) -> Bool {
        let fileURL = messagesDirectory.appendingPathComponent("\(messageId).html")
        return accountBoundary.perform(
            directoryKey: directoryKey,
            expectedGeneration: expectedGeneration
        ) {
            cachedFileSignature(for: fileURL, cacheMissing: true) != "missing"
        } ?? false
    }

    func htmlFileSignature(for messageId: String) -> String {
        let fileURL = messagesDirectory.appendingPathComponent("\(messageId).html")
        return accountBoundary.perform(directoryKey: directoryKey, expectedGeneration: nil) {
            cachedFileSignature(for: fileURL, cacheMissing: true)
        } ?? "missing"
    }

    func htmlSourceSignature(messageId: String, bodyStorageURI: String?) -> String {
        htmlSourceSignature(
            messageId: messageId,
            bodyStorageURI: bodyStorageURI,
            expectedGeneration: nil
        )
    }

    func htmlSourceSignature(
        messageId: String,
        bodyStorageURI: String?,
        expectedGeneration: HTMLContentAccountGeneration?
    ) -> String {
        accountBoundary.perform(
            directoryKey: directoryKey,
            expectedGeneration: expectedGeneration
        ) {
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
        } ?? "missing"
    }

    func canonicalHTMLSourceSignature(messageId: String, bodyStorageURI: String?) -> String? {
        canonicalHTMLSourceSignature(
            messageId: messageId,
            bodyStorageURI: bodyStorageURI,
            expectedGeneration: nil
        )
    }

    func canonicalHTMLSourceSignature(
        messageId: String,
        bodyStorageURI: String?,
        expectedGeneration: HTMLContentAccountGeneration?
    ) -> String? {
        let primaryFileURL = messagesDirectory.appendingPathComponent("\(messageId).html")
        if let signature = canonicalHTMLSourceSignature(
            from: loadHTML(from: primaryFileURL, expectedGeneration: expectedGeneration)
        ) {
            return signature
        }

        guard let bodyStorageURI,
              let resolvedURL = StorageURIResolver.resolve(bodyStorageURI),
              resolvedURL.path != primaryFileURL.path else {
            return nil
        }

        return canonicalHTMLSourceSignature(
            from: loadHTML(from: resolvedURL, expectedGeneration: expectedGeneration)
        )
    }

    func canonicalHTMLSourceSignature(for html: String) -> String? {
        canonicalHTMLSourceSignature(from: html)
    }

    func calculateStorageSize() -> Int64 {
        accountBoundary.perform(directoryKey: directoryKey, expectedGeneration: nil) {
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
        } ?? 0
    }

    func cleanupOldFiles(olderThan days: Int) {
        _ = accountBoundary.perform(directoryKey: directoryKey, expectedGeneration: nil) {
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
    }

    func cleanupOrphanedFiles(validMessageIds: Set<String>) {
        _ = accountBoundary.perform(directoryKey: directoryKey, expectedGeneration: nil) {
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

    private func canonicalHTMLSourceSignature(from html: String?) -> String? {
        guard let html = canonicalHTMLSource(from: html) else {
            return nil
        }

        let content = CanonicalEmailContent(
            html: html,
            plainText: nil,
            sourceKind: .html,
            sourceLocation: .messageFile
        )
        return content.hasHTMLSource ? content.sourceSignature : nil
    }

    private func canonicalHTMLSource(from html: String?) -> String? {
        guard let html else { return nil }

        let trimmed = html.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let lowercased = trimmed.lowercased()

        if lowercased.contains("esc-plain-text-styles") ||
            lowercased.contains("esc-plain-main") ||
            lowercased.contains("esc-plain-details") {
            return nil
        }

        return trimmed
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
