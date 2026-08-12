import AVFoundation
import UIKit

struct AttachmentCacheAccountGeneration: Equatable, Sendable {
    fileprivate let value: UInt64
}

/// Thread-safe actor-based cache for attachment images and data.
/// Uses LRUCacheActor internally for proper concurrency.
actor AttachmentCacheActor: MemoryWarningHandler {
    static let shared = AttachmentCacheActor()

    // MARK: - Cache Instances

    private let thumbnailCache: LRUCacheActor<String, UIImage>
    private let fullImageCache: LRUCacheActor<String, UIImage>
    private let dataCache: LRUCacheActor<String, Data>
    private let requestManager = InFlightRequestManager<String, UIImage>()
    private let memoryObserver = MemoryWarningObserver()
    private let loadAttachmentData: @Sendable (String?) async -> Data?
    private var cacheIdentitiesByAttachmentId: [String: Set<String>] = [:]
    private var acceptsAccountWork = true
    private var accountGeneration: UInt64 = 0

    // MARK: - Initialization

    init(
        loadAttachmentData: @escaping @Sendable (String?) async -> Data? = { path in
            AttachmentPaths.loadData(from: path)
        }
    ) {
        self.loadAttachmentData = loadAttachmentData
        // Thumbnail cache: ~50MB (assuming ~100KB per thumbnail)
        self.thumbnailCache = LRUCacheActor(config: .thumbnailCache())

        // Full image cache: ~100MB (for viewing)
        self.fullImageCache = LRUCacheActor(config: .fullImageCache())

        // Data cache: ~25MB (for quick access to raw data)
        self.dataCache = LRUCacheActor(config: CacheConfiguration(
            maxItems: 50,
            maxMemoryBytes: 25 * 1024 * 1024,
            ttlSeconds: nil,
            evictionPolicy: .lru
        ))

        // Observe memory warnings
        Task { @MainActor [weak self] in
            guard let self = self else { return }
            self.memoryObserver.start(handler: self)
        }
    }

    // MARK: - MemoryWarningHandler

    /// Memory pressure empties the caches but must never retire the account
    /// generation: in-flight loads captured the current generation and would
    /// otherwise evict and throw away the image they just decoded.
    func handleMemoryWarning() async {
        await clearCache(level: .aggressive)
    }

    // MARK: - Cache Clear Levels

    enum CacheClearLevel {
        case light      // Clear full images only
        case moderate   // Clear full images and data
        case aggressive // Clear everything
    }

    /// Rejects new account-scoped cache work and invalidates every in-flight
    /// generation. AuthSession calls this before deleting attachment files.
    func closeAdmission() {
        acceptsAccountWork = false
        accountGeneration &+= 1
    }

    func reopenAdmission() {
        acceptsAccountWork = true
    }

    func captureAccountGeneration() -> AttachmentCacheAccountGeneration? {
        guard acceptsAccountWork else { return nil }
        return AttachmentCacheAccountGeneration(value: accountGeneration)
    }

    func isAccountGenerationCurrent(_ generation: AttachmentCacheAccountGeneration) -> Bool {
        acceptsAccountWork && generation.value == accountGeneration
    }

    /// Retires the current account generation and empties every cache.
    /// Only an account transition may advance the generation: `clearCache(level:)`
    /// is also driven by ordinary memory pressure, and bumping the epoch there
    /// would make every in-flight load evict and discard the image it just decoded.
    func clearForAccountTransition() async {
        accountGeneration &+= 1
        await clearCache(level: .aggressive)
    }

    func clearCache(level: CacheClearLevel = .moderate) async {
        switch level {
        case .light:
            await fullImageCache.clear()
        case .moderate:
            await fullImageCache.clear()
            await dataCache.clear()
        case .aggressive:
            // Clear first so identities registered by loads that enter while
            // the cache actors are being awaited remain discoverable.
            cacheIdentitiesByAttachmentId.removeAll()
            await fullImageCache.clear()
            await dataCache.clear()
            await thumbnailCache.clear()
            await requestManager.clearFailedKeys()
        }
    }

    // MARK: - Thumbnail Loading

    func loadThumbnail(
        for attachmentId: String,
        messageId: String? = nil,
        from path: String?
    ) async -> UIImage? {
        guard acceptsAccountWork,
              let path,
              AttachmentPaths.isReadableStoragePath(
                  path,
                  messageId: messageId,
                  attachmentId: attachmentId
              ) else {
            return nil
        }
        let generation = accountGeneration
        let cacheIdentity = registerCacheIdentity(
            attachmentId: attachmentId,
            messageId: messageId
        )
        let cacheKey = Self.thumbnailCacheKey(
            cacheIdentity,
            sourcePath: path,
            generation: generation
        )

        // Check memory cache
        if let cached = await thumbnailCache.get(cacheKey) {
            guard acceptsAccountWork, generation == accountGeneration else { return nil }
            return cached
        }

        // Use request manager for deduplication
        let loadAttachmentData = self.loadAttachmentData
        let result = await requestManager.deduplicated(key: cacheKey) {
            // Load from disk
            guard let data = await loadAttachmentData(path) else {
                return nil
            }

            // Decode image
            return UIImage(data: data)
        }

        guard acceptsAccountWork, generation == accountGeneration else { return nil }

        // Cache the result
        if let image = result {
            let cost = image.jpegData(compressionQuality: 0.8)?.count ?? 0
            await thumbnailCache.set(cacheKey, value: image, sizeBytes: cost)
            guard acceptsAccountWork, generation == accountGeneration else {
                await thumbnailCache.remove(cacheKey)
                return nil
            }
            cacheIdentitiesByAttachmentId[attachmentId, default: []].insert(cacheIdentity)
        }

        return result
    }

    // MARK: - Video Thumbnail Loading

    /// Extracts and caches a poster frame for a video attachment. Routed
    /// through the same budgeted, memory-pressure-evictable thumbnail LRU as
    /// every other attachment image, so decoded video frames are never pinned
    /// outside the cache's budget and re-appearing cards hit the cache
    /// instead of re-running AVAssetImageGenerator.
    func loadVideoThumbnail(
        for attachmentId: String,
        messageId: String? = nil,
        from path: String?,
        targetSize: CGSize
    ) async -> UIImage? {
        guard targetSize.width > 0, targetSize.height > 0,
              targetSize.width.isFinite, targetSize.height.isFinite else {
            return nil
        }
        guard acceptsAccountWork,
              let path,
              AttachmentPaths.isReadableStoragePath(
                  path,
                  messageId: messageId,
                  attachmentId: attachmentId
              ) else {
            return nil
        }
        let generation = accountGeneration
        let cacheIdentity = registerCacheIdentity(
            attachmentId: attachmentId,
            messageId: messageId
        )
        let cacheKey = Self.videoThumbnailCacheKey(
            cacheIdentity,
            sourcePath: path,
            targetSize: targetSize,
            generation: generation
        )

        // Check memory cache
        if let cached = await thumbnailCache.get(cacheKey) {
            guard acceptsAccountWork, generation == accountGeneration else { return nil }
            return cached
        }

        guard let url = AttachmentPaths.fullURL(for: path) else {
            return nil
        }

        // Capture screen scale on main actor so the frame is sized for the
        // display, not a fixed oversize.
        let scale = await MainActor.run { UIScreen.main.scale }
        let maximumPixelSize = CGSize(
            width: targetSize.width * scale,
            height: targetSize.height * scale
        )

        let result = await requestManager.deduplicated(key: cacheKey) {
            await Self.extractVideoPosterFrame(at: url, maximumPixelSize: maximumPixelSize)
        }

        guard acceptsAccountWork, generation == accountGeneration else { return nil }

        if let image = result {
            let cost = image.jpegData(compressionQuality: 0.8)?.count ?? 0
            await thumbnailCache.set(cacheKey, value: image, sizeBytes: cost)
            guard acceptsAccountWork, generation == accountGeneration else {
                await thumbnailCache.remove(cacheKey)
                return nil
            }
            cacheIdentitiesByAttachmentId[attachmentId, default: []].insert(cacheIdentity)
        }

        return result
    }

    private static func extractVideoPosterFrame(
        at url: URL,
        maximumPixelSize: CGSize
    ) async -> UIImage? {
        let asset = AVAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = maximumPixelSize
        let time = CMTime(seconds: 0.5, preferredTimescale: 600)
        do {
            let (cgImage, _) = try await generator.image(at: time)
            return UIImage(cgImage: cgImage)
        } catch is CancellationError {
            // Not currently reachable: the request manager runs this in its
            // own unstructured Task that no caller cancels — frames complete
            // and get cached, which is what makes scroll-back a cache hit.
            // Kept so a future cancelling caller stays silent here.
            return nil
        } catch {
            // Real extraction failures (undecodable video) must reach the log.
            Log.debug(
                "Video poster frame extraction failed: \(Log.redact(error: error))",
                category: .attachment
            )
            return nil
        }
    }

    // MARK: - Downsampled Image Loading

    func loadDownsampledImage(
        for attachmentId: String,
        messageId: String? = nil,
        from path: String?,
        targetSize: CGSize,
        contentMode: UIView.ContentMode = .scaleAspectFill
    ) async -> UIImage? {
        guard targetSize.width > 0, targetSize.height > 0,
              targetSize.width.isFinite, targetSize.height.isFinite else {
            Log.debug("Skipping downsample for \(attachmentId): invalid target size \(targetSize)", category: .attachment)
            return nil
        }
        guard acceptsAccountWork,
              let path,
              AttachmentPaths.isReadableStoragePath(
                  path,
                  messageId: messageId,
                  attachmentId: attachmentId
              ) else {
            return nil
        }
        let generation = accountGeneration
        let cacheIdentity = registerCacheIdentity(
            attachmentId: attachmentId,
            messageId: messageId
        )

        let cacheKey = Self.downsampledCacheKey(
            cacheIdentity,
            sourcePath: path,
            targetSize: targetSize,
            generation: generation
        )

        // Check memory cache
        if let cached = await fullImageCache.get(cacheKey) {
            guard acceptsAccountWork, generation == accountGeneration else { return nil }
            return cached
        }

        // Load and downsample
        guard let url = AttachmentPaths.fullURL(for: path) else {
            return nil
        }

        // Capture screen scale on main actor before detached task
        let scale = await MainActor.run { UIScreen.main.scale }

        let image = await Task.detached(priority: .userInitiated) {
            self.downsampleImage(at: url, to: targetSize, contentMode: contentMode, scale: scale)
        }.value

        guard acceptsAccountWork, generation == accountGeneration else { return nil }

        // Cache the downsampled image
        if let image = image {
            let cost = Int(targetSize.width * targetSize.height * 4)
            await fullImageCache.set(cacheKey, value: image, sizeBytes: cost)
            guard acceptsAccountWork, generation == accountGeneration else {
                await fullImageCache.remove(cacheKey)
                return nil
            }
            cacheIdentitiesByAttachmentId[attachmentId, default: []].insert(cacheIdentity)
        }

        return image
    }

    private nonisolated func downsampleImage(
        at url: URL,
        to targetSize: CGSize,
        contentMode: UIView.ContentMode,
        scale: CGFloat
    ) -> UIImage? {
        guard targetSize.width > 0, targetSize.height > 0,
              targetSize.width.isFinite, targetSize.height.isFinite,
              scale > 0, scale.isFinite else {
            return nil
        }

        let imageSourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let imageSource = CGImageSourceCreateWithURL(url as CFURL, imageSourceOptions) else {
            return nil
        }

        let maxDimensionInPixels = max(targetSize.width, targetSize.height) * scale
        guard maxDimensionInPixels > 0, maxDimensionInPixels.isFinite else {
            return nil
        }

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

    func loadFullImage(
        for attachmentId: String,
        messageId: String? = nil,
        from path: String?
    ) async -> UIImage? {
        guard acceptsAccountWork,
              let path,
              AttachmentPaths.isReadableStoragePath(
                  path,
                  messageId: messageId,
                  attachmentId: attachmentId
              ) else {
            return nil
        }
        let generation = accountGeneration
        let cacheIdentity = registerCacheIdentity(
            attachmentId: attachmentId,
            messageId: messageId
        )
        let cacheKey = Self.fullImageCacheKey(
            cacheIdentity,
            sourcePath: path,
            generation: generation
        )

        // Check memory cache
        if let cached = await fullImageCache.get(cacheKey) {
            guard acceptsAccountWork, generation == accountGeneration else { return nil }
            return cached
        }

        // Load from disk with size limit
        guard let url = AttachmentPaths.fullURL(for: path) else {
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

        guard acceptsAccountWork, generation == accountGeneration else { return nil }

        // Cache with estimated cost
        if let image = image {
            let cost = Int(image.size.width * image.size.height * 4 * image.scale * image.scale)
            await fullImageCache.set(cacheKey, value: image, sizeBytes: cost)
            guard acceptsAccountWork, generation == accountGeneration else {
                await fullImageCache.remove(cacheKey)
                return nil
            }
            cacheIdentitiesByAttachmentId[attachmentId, default: []].insert(cacheIdentity)
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
        guard acceptsAccountWork else { return }
        let generation = accountGeneration
        let cacheKey = Self.dataCacheKey(key, generation: generation)
        await dataCache.set(cacheKey, value: data, sizeBytes: data.count)
        guard acceptsAccountWork, generation == accountGeneration else {
            await dataCache.remove(cacheKey)
            return
        }
    }

    func getCachedData(for key: String) async -> Data? {
        guard acceptsAccountWork else { return nil }
        let generation = accountGeneration
        let result = await dataCache.get(Self.dataCacheKey(key, generation: generation))
        guard acceptsAccountWork, generation == accountGeneration else { return nil }
        return result
    }

    // MARK: - Preloading

    func preloadThumbnails(
        for attachments: [(messageId: String?, id: String, path: String?)]
    ) {
        guard acceptsAccountWork else { return }
        let generation = accountGeneration
        Task { [weak self] in
            guard let self else { return }
            await withTaskGroup(of: Void.self) { group in
                for (messageId, id, path) in attachments.prefix(10) { // Limit concurrent preloads
                    group.addTask {
                        _ = await self.loadThumbnail(
                            for: id,
                            messageId: messageId,
                            from: path,
                            expectedGeneration: generation
                        )
                    }
                }
            }
        }
    }

    // MARK: - Cache Removal

    /// Removes all cached data for a specific attachment ID.
    /// Use this when an attachment download fails and needs rollback.
    func removeFromCache(_ attachmentId: String) async {
        guard let generation = captureAccountGeneration() else { return }
        await removeFromCache(
            attachmentId,
            expectedAccountGeneration: generation
        )
    }

    /// Removes data only when the caller still belongs to the captured account.
    /// Old Core Data save notifications can otherwise resume after sign-out and
    /// evict a reopened account's entry with the same attachment ID.
    func removeFromCache(
        _ attachmentId: String,
        expectedAccountGeneration: AttachmentCacheAccountGeneration
    ) async {
        guard isAccountGenerationCurrent(expectedAccountGeneration) else { return }
        let generation = expectedAccountGeneration.value
        var cacheIdentities = cacheIdentitiesByAttachmentId.removeValue(
            forKey: attachmentId
        ) ?? []
        // Preserve compatibility for local attachments and callers that pass
        // an already-derived identity rather than a raw attachment ID.
        cacheIdentities.insert(attachmentId)
        for cacheIdentity in cacheIdentities {
            await removeCacheIdentity(cacheIdentity, generation: generation)
        }
    }

    /// Removes only one message's cache entries when sibling messages reuse a
    /// Gmail attachment ID. Rollback uses this path so a failed download cannot
    /// evict a successfully downloaded sibling.
    func removeFromCache(messageId: String?, attachmentId: String) async {
        guard let generation = captureAccountGeneration() else { return }
        await removeFromCache(
            messageId: messageId,
            attachmentId: attachmentId,
            expectedAccountGeneration: generation
        )
    }

    func removeFromCache(
        messageId: String?,
        attachmentId: String,
        expectedAccountGeneration: AttachmentCacheAccountGeneration
    ) async {
        guard isAccountGenerationCurrent(expectedAccountGeneration) else { return }
        guard let messageId, !messageId.isEmpty else {
            await removeFromCache(
                attachmentId,
                expectedAccountGeneration: expectedAccountGeneration
            )
            return
        }
        let cacheIdentity = AttachmentPaths.cacheIdentity(
            messageId: messageId,
            attachmentId: attachmentId
        )
        if var identities = cacheIdentitiesByAttachmentId[attachmentId] {
            identities.remove(cacheIdentity)
            cacheIdentitiesByAttachmentId[attachmentId] = identities.isEmpty ? nil : identities
        }
        await removeCacheIdentity(
            cacheIdentity,
            generation: expectedAccountGeneration.value
        )
    }

    /// Serializes attachment-file deletion with close/reopen admission. The
    /// synchronous file operation cannot interleave with `closeAdmission()` on
    /// this actor, and a retired generation is rejected before touching disk.
    func deleteFile(
        at relativePath: String,
        expectedAccountGeneration: AttachmentCacheAccountGeneration
    ) {
        guard isAccountGenerationCurrent(expectedAccountGeneration) else { return }
        AttachmentPaths.deleteFile(at: relativePath)
    }

    private func loadThumbnail(
        for attachmentId: String,
        messageId: String?,
        from path: String?,
        expectedGeneration: UInt64
    ) async -> UIImage? {
        guard acceptsAccountWork, expectedGeneration == accountGeneration else { return nil }
        return await loadThumbnail(
            for: attachmentId,
            messageId: messageId,
            from: path
        )
    }

    private func registerCacheIdentity(
        attachmentId: String,
        messageId: String?
    ) -> String {
        let cacheIdentity = AttachmentPaths.cacheIdentity(
            messageId: messageId,
            attachmentId: attachmentId
        )
        cacheIdentitiesByAttachmentId[attachmentId, default: []].insert(cacheIdentity)
        return cacheIdentity
    }

    private func removeCacheIdentity(_ cacheIdentity: String, generation: UInt64) async {
        let thumbnailPrefix = Self.thumbnailCachePrefix(
            cacheIdentity,
            generation: generation
        )
        let thumbnailKeys = await thumbnailCache.allKeys().filter {
            $0.hasPrefix(thumbnailPrefix)
        }
        for key in thumbnailKeys {
            await thumbnailCache.remove(key)
        }

        let fullImagePrefix = Self.fullImageCachePrefix(
            cacheIdentity,
            generation: generation
        )
        let fullImageKeys = await fullImageCache.allKeys().filter {
            $0.hasPrefix(fullImagePrefix)
        }
        for key in fullImageKeys {
            await fullImageCache.remove(key)
        }

        let downsampledPrefix = Self.downsampledCachePrefix(
            cacheIdentity,
            generation: generation
        )
        let downsampledKeys = await fullImageCache.allKeys().filter {
            $0.hasPrefix(downsampledPrefix)
        }
        for key in downsampledKeys {
            await fullImageCache.remove(key)
        }

        await dataCache.remove(Self.dataCacheKey(cacheIdentity, generation: generation))
    }

    private nonisolated static func thumbnailCacheKey(
        _ attachmentId: String,
        sourcePath: String,
        generation: UInt64
    ) -> String {
        "\(thumbnailCachePrefix(attachmentId, generation: generation))\(sourcePath)"
    }

    private nonisolated static func thumbnailCachePrefix(
        _ attachmentId: String,
        generation: UInt64
    ) -> String {
        "g\(generation):thumb_\(attachmentId)|"
    }

    private nonisolated static func fullImageCacheKey(
        _ attachmentId: String,
        sourcePath: String,
        generation: UInt64
    ) -> String {
        "\(fullImageCachePrefix(attachmentId, generation: generation))\(sourcePath)"
    }

    private nonisolated static func fullImageCachePrefix(
        _ attachmentId: String,
        generation: UInt64
    ) -> String {
        "g\(generation):full_\(attachmentId)|"
    }

    private nonisolated static func videoThumbnailCacheKey(
        _ attachmentId: String,
        sourcePath: String,
        targetSize: CGSize,
        generation: UInt64
    ) -> String {
        // Shares the thumbnail prefix so identity-based invalidation and the
        // aggressive-clear path cover video frames with no extra bookkeeping.
        "\(thumbnailCachePrefix(attachmentId, generation: generation))video|\(sourcePath)|\(Int(targetSize.width))x\(Int(targetSize.height))"
    }

    private nonisolated static func downsampledCacheKey(
        _ attachmentId: String,
        sourcePath: String,
        targetSize: CGSize,
        generation: UInt64
    ) -> String {
        "\(downsampledCachePrefix(attachmentId, generation: generation))\(sourcePath)|\(Int(targetSize.width))x\(Int(targetSize.height))"
    }

    private nonisolated static func downsampledCachePrefix(
        _ attachmentId: String,
        generation: UInt64
    ) -> String {
        "g\(generation):downsampled_\(attachmentId)|"
    }

    private nonisolated static func dataCacheKey(
        _ key: String,
        generation: UInt64
    ) -> String {
        "g\(generation):\(key)"
    }
}
