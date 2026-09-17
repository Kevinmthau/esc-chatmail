import Foundation

struct ProcessedTextCacheAccountGeneration: Equatable, Sendable {
    fileprivate let value: UInt64
}

/// Thread-safe cache for processed message text content
/// Eliminates redundant HTML parsing and regex operations during scroll
/// Uses LRUCacheActor for automatic eviction management
actor ProcessedTextCache: MemoryWarningHandler {
    static let shared = ProcessedTextCache()
    // Bump to invalidate cached entries when processing logic changes.
    private static let processingVersion = CacheVersioning.processedTextProcessingVersion

    /// Cached text content with rich content indicator and extracted quotes
    struct CachedText: Sendable {
        let plainText: String?
        let hasRichContent: Bool
        let quotedParts: [QuotedPart]

        init(
            plainText: String?,
            hasRichContent: Bool,
            quotedParts: [QuotedPart] = []
        ) {
            self.plainText = plainText
            self.hasRichContent = hasRichContent
            self.quotedParts = quotedParts
        }
    }

    private let cache: LRUCacheActor<String, CachedText>
    private var cacheKeysByMessageID: [String: Set<String>] = [:]
    private var cacheKeyTrackingVersion: UInt64 = 0
    private var inFlightTrackedCacheWriteCount = 0

    /// Track active prefetch task to prevent unbounded task accumulation
    private var activePrefetchTask: Task<Void, Never>?

    /// Track task identity to prevent cancelled tasks from clearing newer task references
    private var activePrefetchTaskId: UUID?
    private var acceptsAccountWork = true
    private var accountGeneration: UInt64 = 0

    /// Maximum number of messages to process in a single prefetch batch
    private let maxPrefetchBatchSize = 20

    /// Observes memory warnings to clear cache under pressure
    private let memoryObserver = MemoryWarningObserver()

    init() {
        self.cache = LRUCacheActor(config: CacheConfiguration(
            maxItems: CacheConfig.textCacheSize,
            maxMemoryBytes: CacheConfig.textCacheMaxBytes,
            ttlSeconds: nil,
            evictionPolicy: .lru
        ))
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.memoryObserver.start(handler: self)
        }
    }

    func handleMemoryWarning() async {
        await cache.clear()
        cacheKeysByMessageID.removeAll()
        cacheKeyTrackingVersion &+= 1
        Log.info("ProcessedTextCache cleared due to memory warning", category: .coreData)
    }

    /// Estimates memory size of a cached text entry
    private static func estimateSize(_ plainText: String?, _ hasRichContent: Bool, _ quotedParts: [QuotedPart] = []) -> Int {
        // String size: UTF-8 bytes + some overhead
        let textSize = (plainText?.utf8.count ?? 0)
        // QuotedPart size: String header (16 bytes) + String data + Optional<String> (1 byte + 16 if present) + Int (8 bytes) + alignment padding
        // Estimated 56 bytes per QuotedPart struct overhead
        let quotedSize = quotedParts.reduce(0) { sum, part in
            sum + part.text.utf8.count + (part.attribution?.utf8.count ?? 0) + 56
        }
        // Bool size + struct overhead
        let overheadSize = 24
        return textSize + quotedSize + overheadSize
    }

    private static func cacheKey(for messageId: String, accountGeneration: UInt64) -> String {
        "account:\(accountGeneration)|\(processingVersion)|\(messageId)"
    }

    private static func cacheKey(
        for messageId: String,
        sourceSignature: String,
        previewMode: String,
        accountGeneration: UInt64
    ) -> String {
        "account:\(accountGeneration)|\(processingVersion)|\(messageId)|source:\(sourceSignature)|mode:\(previewMode)"
    }

    func get(
        messageId: String,
        expectedAccountGeneration: ProcessedTextCacheAccountGeneration? = nil
    ) async -> (plainText: String?, hasRichContent: Bool, quotedParts: [QuotedPart])? {
        guard let generation = resolvedAccountGeneration(expectedAccountGeneration) else { return nil }
        guard let entry = await cache.get(Self.cacheKey(
            for: messageId,
            accountGeneration: generation
        )) else { return nil }
        guard acceptsAccountWork, generation == accountGeneration else { return nil }
        return (entry.plainText, entry.hasRichContent, entry.quotedParts)
    }

    func get(
        messageId: String,
        sourceSignature: String,
        previewMode: String,
        expectedAccountGeneration: ProcessedTextCacheAccountGeneration? = nil
    ) async -> (
        plainText: String?,
        hasRichContent: Bool,
        quotedParts: [QuotedPart]
    )? {
        guard let generation = resolvedAccountGeneration(expectedAccountGeneration) else { return nil }
        let key = Self.cacheKey(
            for: messageId,
            sourceSignature: sourceSignature,
            previewMode: previewMode,
            accountGeneration: generation
        )
        guard let entry = await cache.get(key) else { return nil }
        guard acceptsAccountWork, generation == accountGeneration else { return nil }
        return (
            entry.plainText,
            entry.hasRichContent,
            entry.quotedParts
        )
    }

    func set(
        messageId: String,
        plainText: String?,
        hasRichContent: Bool,
        quotedParts: [QuotedPart] = [],
        expectedAccountGeneration: ProcessedTextCacheAccountGeneration? = nil
    ) async {
        guard let generation = resolvedAccountGeneration(expectedAccountGeneration) else { return }
        let size = Self.estimateSize(plainText, hasRichContent, quotedParts)
        let key = Self.cacheKey(for: messageId, accountGeneration: generation)
        beginTrackedCacheWrite(key, for: messageId)
        await cache.set(
            key,
            value: CachedText(
                plainText: plainText,
                hasRichContent: hasRichContent,
                quotedParts: quotedParts
            ),
            sizeBytes: size
        )
        finishTrackedCacheWrite()
        guard acceptsAccountWork, generation == accountGeneration else {
            await cache.remove(key)
            return
        }
        await pruneTrackedCacheKeys()
    }

    func set(
        messageId: String,
        sourceSignature: String,
        previewMode: String,
        plainText: String?,
        hasRichContent: Bool,
        quotedParts: [QuotedPart] = [],
        expectedAccountGeneration: ProcessedTextCacheAccountGeneration? = nil
    ) async {
        guard let generation = resolvedAccountGeneration(expectedAccountGeneration) else { return }
        let size = Self.estimateSize(plainText, hasRichContent, quotedParts)
        let key = Self.cacheKey(
            for: messageId,
            sourceSignature: sourceSignature,
            previewMode: previewMode,
            accountGeneration: generation
        )
        beginTrackedCacheWrite(key, for: messageId)
        await cache.set(
            key,
            value: CachedText(
                plainText: plainText,
                hasRichContent: hasRichContent,
                quotedParts: quotedParts
            ),
            sizeBytes: size
        )
        finishTrackedCacheWrite()
        guard acceptsAccountWork, generation == accountGeneration else {
            await cache.remove(key)
            return
        }
        await pruneTrackedCacheKeys()
    }

    /// Prefetches compatibility fallback text for old messages without chatPreviewText.
    func prefetch(messageIds: [String]) async {
        guard acceptsAccountWork else { return }
        let generation = accountGeneration
        // Filter out already cached messages
        var uncachedMessages: [(messageId: String, sourceSignature: String)] = []
        let signatureHandler = HTMLContentHandler.shared
        guard let htmlGeneration = signatureHandler.captureAccountGeneration() else { return }
        for messageId in messageIds {
            let sourceSignature = MessageBubbleContentSource.contentSourceSignature(
                messageId: messageId,
                bodyStorageURI: nil,
                bodyText: nil,
                handler: signatureHandler,
                expectedAccountGeneration: htmlGeneration
            )
            let key = Self.cacheKey(
                for: messageId,
                sourceSignature: sourceSignature,
                previewMode: MessageBubbleContentSource.chatBubblePreviewMode,
                accountGeneration: generation
            )
            if await !cache.contains(key) {
                uncachedMessages.append((messageId, sourceSignature))
            }
        }
        guard !uncachedMessages.isEmpty else { return }

        // Limit batch size to prevent processing too many at once
        let messagesToProcess = Array(uncachedMessages.prefix(maxPrefetchBatchSize))

        // Cancel any existing prefetch task to prevent accumulation during rapid scroll
        activePrefetchTask?.cancel()

        // Generate unique ID for this task to prevent race conditions on cleanup
        let taskId = UUID()
        activePrefetchTaskId = taskId

        // Track the new prefetch task
        activePrefetchTask = Task.detached(priority: .utility) { [weak self, messagesToProcess, taskId, generation, htmlGeneration] in
            let handler = HTMLContentHandler.shared

            for (messageId, sourceSignature) in messagesToProcess {
                // Check for cancellation between messages
                guard !Task.isCancelled else { break }

                let result = MessageBubbleContentSource.processMessage(
                    messageId: messageId,
                    handler: handler,
                    expectedAccountGeneration: htmlGeneration
                )

                // Check again before cache write to prevent cancelled tasks from writing stale data
                guard !Task.isCancelled,
                      await self?.isCurrentAccountGeneration(generation) == true else {
                    break
                }

                await self?.set(
                    messageId: messageId,
                    sourceSignature: sourceSignature,
                    previewMode: MessageBubbleContentSource.chatBubblePreviewMode,
                    plainText: result.plainText,
                    hasRichContent: result.hasRichContent,
                    quotedParts: result.quotedParts,
                    expectedAccountGeneration: ProcessedTextCacheAccountGeneration(value: generation)
                )
            }

            // Clear task reference on completion, but only if this is still the active task
            // (prevents cancelled tasks from clearing a newer task's reference)
            await self?.clearPrefetchTaskIfMatches(taskId)
        }
    }

    /// Clears the prefetch task reference only if it matches the given task ID
    private func clearPrefetchTaskIfMatches(_ taskId: UUID) {
        if activePrefetchTaskId == taskId {
            activePrefetchTask = nil
            activePrefetchTaskId = nil
        }
    }

    /// Cancel any active prefetch task (call when view disappears)
    func cancelPrefetch() {
        activePrefetchTask?.cancel()
        activePrefetchTask = nil
        activePrefetchTaskId = nil
    }

    func closeAccountWorkAndClear() async {
        acceptsAccountWork = false
        accountGeneration &+= 1
        let prefetchTask = activePrefetchTask
        prefetchTask?.cancel()
        if let prefetchTask {
            await prefetchTask.value
        }
        activePrefetchTask = nil
        activePrefetchTaskId = nil
        await clear()
    }

    func reopenAccountWork() {
        accountGeneration &+= 1
        acceptsAccountWork = true
    }

    func captureAccountGeneration() -> ProcessedTextCacheAccountGeneration? {
        guard acceptsAccountWork else { return nil }
        return ProcessedTextCacheAccountGeneration(value: accountGeneration)
    }

    func isAccountGenerationCurrent(_ generation: ProcessedTextCacheAccountGeneration) -> Bool {
        acceptsAccountWork && generation.value == accountGeneration
    }

    private func resolvedAccountGeneration(
        _ expectedGeneration: ProcessedTextCacheAccountGeneration?
    ) -> UInt64? {
        guard acceptsAccountWork else { return nil }
        if let expectedGeneration {
            guard expectedGeneration.value == accountGeneration else { return nil }
            return expectedGeneration.value
        }
        return accountGeneration
    }

    private func isCurrentAccountGeneration(_ generation: UInt64) -> Bool {
        acceptsAccountWork && generation == accountGeneration
    }

    func clear() async {
        await cache.clear()
        cacheKeysByMessageID.removeAll()
        cacheKeyTrackingVersion &+= 1
    }

    /// Invalidates a specific cache entry by message ID.
    /// Use this when a Message entity is deleted.
    func invalidate(messageId: String) async {
        await invalidate(
            messageId: messageId,
            expectedAccountGeneration: nil,
            invalidatesRenderedMessage: true
        )
    }

    func invalidate(
        messageId: String,
        expectedAccountGeneration: ProcessedTextCacheAccountGeneration,
        invalidatesRenderedMessage: Bool
    ) async {
        await invalidate(
            messageId: messageId,
            expectedAccountGeneration: Optional(expectedAccountGeneration),
            invalidatesRenderedMessage: invalidatesRenderedMessage
        )
    }

    private func invalidate(
        messageId: String,
        expectedAccountGeneration: ProcessedTextCacheAccountGeneration?,
        invalidatesRenderedMessage: Bool
    ) async {
        guard let generation = resolvedAccountGeneration(expectedAccountGeneration) else { return }
        let trackedKeys = cacheKeysByMessageID.removeValue(forKey: messageId) ?? []
        cacheKeyTrackingVersion &+= 1
        let legacyKey = Self.cacheKey(
            for: messageId,
            accountGeneration: generation
        )
        for key in trackedKeys.union([legacyKey]) {
            await cache.remove(key)
        }
        guard isCurrentAccountGeneration(generation) else { return }
        if invalidatesRenderedMessage {
            await RenderedMessageCache.shared.invalidate(messageId: messageId, reason: .explicit)
        }
    }

    /// Returns cache statistics for monitoring
    func getStatistics() async -> LRUCacheStatistics {
        await cache.getStatistics()
    }

    private func trackCacheKey(_ key: String, for messageId: String) {
        cacheKeysByMessageID[messageId, default: []].insert(key)
        cacheKeyTrackingVersion &+= 1
    }

    private func beginTrackedCacheWrite(_ key: String, for messageId: String) {
        inFlightTrackedCacheWriteCount += 1
        trackCacheKey(key, for: messageId)
    }

    private func finishTrackedCacheWrite() {
        guard inFlightTrackedCacheWriteCount > 0 else { return }
        inFlightTrackedCacheWriteCount -= 1
    }

    private func pruneTrackedCacheKeys() async {
        guard inFlightTrackedCacheWriteCount == 0 else {
            return
        }

        let trackingVersion = cacheKeyTrackingVersion
        let liveKeys = Set(await cache.allKeys())
        guard cacheKeyTrackingVersion == trackingVersion,
              inFlightTrackedCacheWriteCount == 0 else {
            return
        }

        cacheKeysByMessageID = cacheKeysByMessageID.reduce(into: [:]) { result, entry in
            let retainedKeys = entry.value.intersection(liveKeys)
            if !retainedKeys.isEmpty {
                result[entry.key] = retainedKeys
            }
        }
        cacheKeyTrackingVersion &+= 1
    }

#if DEBUG
    func trackedCacheKeyCountForTesting() -> Int {
        cacheKeysByMessageID.values.reduce(0) { $0 + $1.count }
    }

    func beginTrackedCacheWriteForTesting(messageId: String, sourceSignature: String, previewMode: String) {
        let key = Self.cacheKey(
            for: messageId,
            sourceSignature: sourceSignature,
            previewMode: previewMode,
            accountGeneration: accountGeneration
        )
        beginTrackedCacheWrite(key, for: messageId)
    }

    func finishTrackedCacheWriteForTesting() {
        finishTrackedCacheWrite()
    }
#endif
}
