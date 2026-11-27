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

    /// A read of the directory that answers while the boundary is closed, for the
    /// account-isolation gate alone (`HTMLContentHandler.hasStoredHTMLFiles`). It
    /// takes the lock, so it never overlaps a body read or write, and checks
    /// neither `acceptsWork` nor the generation: the question it answers is what is
    /// on disk, which a closed boundary knows as well as an open one. The lock
    /// orders nothing against the cleanup's rename, which
    /// `deleteAllHTMLFromClosedAccount` runs in a detached task outside it: what
    /// keeps the two apart is that both run only under the auth-transition gate, so
    /// this is for a caller inside a transition and no other. Not for any reader or
    /// writer of a body: those go through `perform`, whose nil while closed is what
    /// keeps old-account content out of the next account.
    func inspect<T>(_ operation: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try operation()
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
            // One rename, however many bodies there are; the unlinks follow in the
            // background and nothing waits for them (`RetiredAccountDirectory`).
            // `reopenAccountWork` makes the directory again.
            RetiredAccountDirectory.removeInBackground(
                try RetiredAccountDirectory.takeOutOfUse(directory)
            )
        }
        createMessagesDirectoryIfNeeded()
    }

    private func createMessagesDirectoryIfNeeded() {
        _ = accountBoundary.perform(directoryKey: directoryKey, expectedGeneration: nil) {
            if !FileManager.default.fileExists(atPath: messagesDirectory.path) {
                FileSystemErrorHandler.createDirectory(at: messagesDirectory, category: .general)
            }
            excludeMessagesDirectoryFromBackup()
        }
    }

    /// Message bodies can be fetched again, and at a large mailbox they are gigabytes. Called
    /// wherever the directory is created or found, because the mark is the directory's own:
    /// a directory made again after a sign-out has none, and neither has one from a build
    /// before the mark (`BackupExclusion`). The bodies stay where they are: the verdict and
    /// preview passes read them as stored state, so they must never become purgeable.
    private func excludeMessagesDirectoryFromBackup() {
        BackupExclusion.exclude(messagesDirectory)
    }

    /// Ensures the Messages directory exists. Call after cleanup operations that may delete it.
    func ensureDirectoryExists() {
        createMessagesDirectoryIfNeeded()
    }

    /// Reports whether canonical message HTML survived without a corresponding
    /// account row, as can happen after sign-out on an older app version.
    ///
    /// Read through the boundary's `inspect`, which answers while the boundary is
    /// closed. The account-isolation gate asks this during
    /// `prepareLocalStoreForAuthenticatedAccount`, and a sign-in that follows a
    /// sign-out in the same process prepares its store with the boundary still
    /// closed: `signIn` reopens account work only after the preparation returns
    /// (the fixed transition order), and nothing but that reopen opens the
    /// boundary. Until 2026-11-27 this was `perform(…) ?? true`, so a closed
    /// boundary read as "stored HTML" for an empty mailbox, the gate wrote its
    /// reset marker again and the whole durable cleanup ran a second time over a
    /// store that was already empty (architecture review 2026-11,
    /// account-boundary-auth#3). A closed boundary admits no writer and the gate
    /// runs under the auth-transition gate, so the listing is accurate. It lists
    /// the live directory only: a sign-out's tombstone is a sibling of it, never
    /// inside it, and is not another account's HTML. Only a missing directory is
    /// "no files"; any other error throws, because an unreadable directory does
    /// not prove another account's bodies are absent.
    func hasStoredHTMLFiles() throws -> Bool {
        try accountBoundary.inspect {
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
        }
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
    ///
    /// What is awaited is one rename of the Messages directory to a tombstone, not the
    /// removal of its files, which goes on in the background after this returns
    /// (`RetiredAccountDirectory`). Until `reopenAccountWork()` there is no Messages
    /// directory. `hasStoredHTMLFiles()` does not count a tombstone: no body in one can be
    /// reached by a message of the next account.
    func deleteAllHTMLFromClosedAccount() async throws {
        #if os(macOS)
        // Outside the App Sandbox this is the user's real ~/Documents/Messages.
        // Account removal runs this before AuthSession's attachment cleanup,
        // so it needs its own guard (docs/mac-app-plan.md, PR C).
        try SandboxTripwire.ensureDestructiveCleanupPermitted(.accountRemovalMessageBodies)
        #endif
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
            excludeMessagesDirectoryFromBackup()
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
        saveHTMLResult(html, for: messageId, expectedGeneration: expectedGeneration).savedURL
    }

    /// `saveHTML` with the reason a write did not happen. Sync persistence needs it: a closed
    /// boundary is teardown, a full volume stops the whole run, and any other write failure
    /// blocks only this message. All three used to come back as the same nil, so a full disk
    /// stored a body-less row behind an advancing cursor.
    func saveHTMLResult(
        _ html: String,
        for messageId: String,
        expectedGeneration: HTMLContentAccountGeneration? = nil
    ) -> HTMLSaveResult {
        let fileURL = messagesDirectory.appendingPathComponent("\(messageId).html")

        do {
            guard let savedURL = try accountBoundary.perform(
                directoryKey: directoryKey,
                expectedGeneration: expectedGeneration,
                {
                    do {
                        try html.write(to: fileURL, atomically: true, encoding: .utf8)
                    } catch {
                        // The directory is created only at init and on reopen, so one that is
                        // gone (its creation failed on a full disk, or something removed it)
                        // would fail every later write, and sync would mark each message as its
                        // own failure. Recreate it under the boundary and retry once. A
                        // creation that fails throws its own error, so a full disk still reads
                        // as out of space.
                        guard !FileManager.default.fileExists(atPath: messagesDirectory.path) else {
                            throw error
                        }
                        try FileManager.default.createDirectory(
                            at: messagesDirectory,
                            withIntermediateDirectories: true
                        )
                        excludeMessagesDirectoryFromBackup()
                        try html.write(to: fileURL, atomically: true, encoding: .utf8)
                    }
                    cacheHTML(html, for: fileURL)
                    refreshSignatureCache(for: fileURL)
                    return fileURL
                }
            ) else {
                return .boundaryClosed
            }
            return .saved(savedURL)
        } catch {
            Log.error("Failed to save HTML for message \(Log.hashIdentifier(messageId))", category: .general, error: error)
            return .writeFailed(error)
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
            // A file removed behind the handler's back can still have a positive
            // signature cached, and `htmlFileExists` answers from that cache: it would
            // go on reporting a file that every load then fails to read, which
            // `RichContentVerdictResolver` treats as "exists but unreadable". A cached
            // "missing" is left alone; dropping it would re-stat the file on the next
            // signature read of every HTML-less message.
            invalidateStalePresentSignature(for: url)
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

    /// The body file's URL when it already holds exactly `html`, so a refetch can skip
    /// rewriting identical bytes (`MessagePersister`'s update path). Nil when the file is
    /// missing, holds anything else, or the boundary is closed.
    ///
    /// Reads the file itself, never `htmlContentCache`. That cache is process-wide and keeps a
    /// body after its file is removed behind the handler's back, and approving the skip from it
    /// left `bodyStorageURI` pointing at nothing while the refetch carried the very bytes that
    /// would have restored the file. The read costs less than the write it can save, and this
    /// runs only on a refetch of a row that already has a body.
    func storedHTMLURL(ifMatching html: String, for messageId: String) -> URL? {
        let fileURL = messagesDirectory.appendingPathComponent("\(messageId).html")
        let matches = accountBoundary.perform(
            directoryKey: directoryKey,
            expectedGeneration: nil
        ) {
            (try? String(contentsOf: fileURL, encoding: .utf8)) == html
        } ?? false
        return matches ? fileURL : nil
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

    /// Removes the body files of messages a save deleted, some time after that save.
    ///
    /// Each chunk's unlinks are one turn under the boundary's lock, so a writer of the same
    /// directory waits for a hundred unlinks at most, and a closed or retired boundary stops
    /// the removal at the next chunk. Within a chunk a file is left where the store has a row
    /// for its message again, or where it was written after the delete
    /// (`DeletedRowFileReclamation`). `deleteHTML(for:bodyStorageURI:)` asks neither, and
    /// from this path it removed the body of a message that had been taken out of Trash
    /// and stored again before the removal ran.
    ///
    /// The store is asked before the lock is taken, never with it held. Every HTML read and
    /// write takes that lock, and so does every context's save with something to invalidate,
    /// whose notification captures the boundary's generation for `CacheCoordinator` (a save
    /// with nothing to invalidate takes it no longer: `CacheCoordinator.savePlan`); asked
    /// inside it, a fetch kept the main thread's body loads and every such save in the app
    /// waiting for as long as it took.
    /// The answer can be older than the unlink, and that is covered by the file's date,
    /// which is read under the lock just before the unlink: every body write takes the lock,
    /// so a body written after the answer was written after the delete and is left. What
    /// that leaves open is a row saved in between whose body was written before the delete
    /// was posted, a store of the message concurrent with its deletion; sync's runs are
    /// single-flight, so its delete and a later store of the same message come one after
    /// the other.
    ///
    /// - Parameters:
    ///   - deletedAt: When the deleting save was posted.
    ///   - liveMessageIDs: The IDs among those given that a stored row has. Called with no
    ///     lock held, and only while the boundary still belongs to `expectedGeneration`. A
    ///     throw removes nothing of that chunk.
    ///   - isCancelled: Asked before each chunk.
    func deleteHTML(
        forDeleted bodies: [DeletedMessageBody],
        deletedAt: Date,
        expectedGeneration: HTMLContentAccountGeneration,
        chunkSize: Int = 100,
        liveMessageIDs: (Set<String>) throws -> Set<String>,
        isCancelled: () -> Bool = { Task.isCancelled }
    ) {
        let chunkSize = max(1, chunkSize)
        var start = 0
        while start < bodies.count {
            guard !isCancelled() else { return }
            let chunk = bodies[start..<min(start + chunkSize, bodies.count)]
            start += chunkSize
            // A retired account's removal does not even ask the store. The lock is taken
            // and let go here; the unlinks below check the generation again under it.
            guard isAccountGenerationCurrent(expectedGeneration) else { return }
            let live: Set<String>
            do {
                live = try liveMessageIDs(Set(chunk.map(\.messageId)))
            } catch {
                Log.error(
                    "Leaving deleted messages' body files: stored rows could not be read",
                    category: .general,
                    error: error
                )
                continue
            }
            let admitted: Void? = accountBoundary.perform(
                directoryKey: directoryKey,
                expectedGeneration: expectedGeneration
            ) {
                for body in chunk where !live.contains(body.messageId) {
                    let fileURL = messagesDirectory.appendingPathComponent("\(body.messageId).html")
                    removeDeletedBodyFile(at: fileURL, deletedAt: deletedAt)

                    guard let bodyStorageURI = body.bodyStorageURI,
                          let resolvedURL = StorageURIResolver.resolve(bodyStorageURI),
                          resolvedURL.path != fileURL.path else {
                        continue
                    }
                    removeDeletedBodyFile(at: resolvedURL, deletedAt: deletedAt)
                }
            }
            // Closed, or reopened for another account: nothing later is this caller's.
            guard admitted != nil else { return }
        }
    }

    private func removeDeletedBodyFile(at fileURL: URL, deletedAt: Date) {
        guard !DeletedRowFileReclamation.wasWrittenAfter(deletedAt, fileAt: fileURL) else {
            return
        }
        FileSystemErrorHandler.removeItem(at: fileURL, category: .general)
        invalidateCaches(for: fileURL)
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

    /// Reads only signatures already cached by normal source access. A missing entry is
    /// unknown, not a missing file: mounting a chat row must not stat or read its HTML.
    func cachedHTMLSourceSignature(
        messageId: String,
        bodyStorageURI: String?,
        expectedGeneration: HTMLContentAccountGeneration
    ) -> String? {
        accountBoundary.perform(directoryKey: directoryKey, expectedGeneration: expectedGeneration) {
            let primaryFileURL = messagesDirectory.appendingPathComponent("\(messageId).html")
            guard let primarySignature = Self.fileSignatureCache.object(
                forKey: cacheKey(for: primaryFileURL)
            ) as String? else { return nil }
            guard primarySignature == "missing", let bodyStorageURI,
                  let resolvedURL = StorageURIResolver.resolve(bodyStorageURI),
                  resolvedURL.path != primaryFileURL.path else {
                return primarySignature
            }
            return Self.fileSignatureCache.object(forKey: cacheKey(for: resolvedURL)) as String?
        } ?? nil
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

    func cleanupOrphanedFiles(
        validMessageIds: Set<String>,
        expectedGeneration: HTMLContentAccountGeneration? = nil
    ) {
        #if os(macOS)
        // Outside the App Sandbox this sweep would delete every file in the
        // user's real ~/Documents/Messages (docs/mac-app-plan.md, PR C).
        guard SandboxTripwire.permitsDestructiveCleanup(.orphanedMessageBodySweep) else {
            return
        }
        #endif
        _ = accountBoundary.perform(directoryKey: directoryKey, expectedGeneration: expectedGeneration) {
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

    private func invalidateStalePresentSignature(for fileURL: URL) {
        let cacheKey = cacheKey(for: fileURL)
        if let cached = Self.fileSignatureCache.object(forKey: cacheKey), cached != "missing" {
            Self.fileSignatureCache.removeObject(forKey: cacheKey)
        }
    }

    private func clearCaches() {
        Self.htmlContentCache.removeAllObjects()
        Self.fileSignatureCache.removeAllObjects()
    }
}
