import Foundation

/// In-memory LRU cache for prepared `HTMLLoadResult`s.
///
/// Results are keyed by a content-derived cache key, with a parallel
/// variant-key → cache-key index so a message's cached display variants can be
/// looked up and invalidated. Backed by `NSCache` (count + cost limits drive
/// memory-pressure eviction) plus two tracking dictionaries.
///
/// Thread-safety / lock discipline: an `NSLock` guards the tracking
/// dictionaries (`NSCache` is itself internally synchronized). Every `NSCache`
/// mutation (`setObject` / `removeObject`) is performed OUTSIDE the lock,
/// because eviction re-enters this type via the cache delegate
/// (`removeTrackedCacheKey`), which takes the same lock — holding it across an
/// `NSCache` write would deadlock.
final class HTMLContentResultCache {
    private let cache = NSCache<NSString, CachedHTMLLoadResultBox>()
    private let delegate = HTMLContentCacheDelegate()
    private let lock = NSLock()
    private var keysByMessageID: [String: Set<String>] = [:]
    private var keyByVariantKey: [String: String] = [:]

    init() {
        // Limit cache to ~50MB with both count and cost limits for proper memory pressure response
        cache.countLimit = 1000
        cache.totalCostLimit = 50 * 1024 * 1024 // 50 MB
        cache.delegate = delegate
        delegate.owner = self
    }

    // MARK: - Lookup

    /// Returns the cached result stored directly under `cacheKey`, if any.
    func result(forKey cacheKey: NSString) -> HTMLLoadResult? {
        cache.object(forKey: cacheKey)?.result
    }

    /// Returns the cached result for a display variant whose source is no longer
    /// available, resolving `variantKey` → tracked cache key → result. Self-heals
    /// the index if the tracked entry has since been evicted.
    func resultForVariant(_ variantKey: String) -> HTMLLoadResult? {
        let trackedCacheKey: String?

        lock.lock()
        trackedCacheKey = keyByVariantKey[variantKey]
        lock.unlock()

        guard let trackedCacheKey else {
            return nil
        }

        if let cachedResult = cache.object(forKey: trackedCacheKey as NSString) {
            return cachedResult.result
        }

        removeTrackedVariantKey(variantKey, ifMappedTo: trackedCacheKey)
        return nil
    }

    // MARK: - Store

    /// Stores `result` under `cacheKey`, updating the variant index and evicting
    /// any stale entry the variant previously mapped to.
    func store(
        _ result: HTMLLoadResult,
        cacheKey: NSString,
        variantKey: NSString,
        messageId: String,
        cost: Int
    ) {
        let trackedCacheKey = cacheKey as String
        let trackedVariantKey = variantKey as String
        let staleCacheKey = trackCacheKey(trackedCacheKey, variantKey: trackedVariantKey, for: messageId)
        if let staleCacheKey {
            cache.removeObject(forKey: staleCacheKey as NSString)
        }
        cache.setObject(
            CachedHTMLLoadResultBox(
                result,
                cacheKey: trackedCacheKey,
                variantKey: trackedVariantKey,
                messageId: messageId
            ),
            forKey: cacheKey,
            cost: cost
        )
    }

    // MARK: - Invalidate

    /// Removes every cached variant of `messageId` whose source matches
    /// `shouldInvalidate`. Untracked-but-evicted keys are dropped too.
    func invalidate(
        messageId: String,
        matching shouldInvalidate: (HTMLLoadResult.HTMLLoadSource) -> Bool
    ) {
        let keys: [String]
        lock.lock()
        let trackedKeys = keysByMessageID[messageId] ?? []
        keys = trackedKeys.filter { key in
            guard let box = cache.object(forKey: key as NSString) else {
                return true
            }
            return shouldInvalidate(box.result.source)
        }
        if !keys.isEmpty {
            let keySet = Set(keys)
            let remainingKeys = trackedKeys.subtracting(keySet)
            if remainingKeys.isEmpty {
                keysByMessageID.removeValue(forKey: messageId)
            } else {
                keysByMessageID[messageId] = remainingKeys
            }
            keyByVariantKey = keyByVariantKey.filter { !keySet.contains($0.value) }
        }
        lock.unlock()

        for key in keys {
            cache.removeObject(forKey: key as NSString)
        }
    }

    // MARK: - Tracking

    private func trackCacheKey(_ cacheKey: String, variantKey: String, for messageId: String) -> String? {
        lock.lock()
        let staleCacheKey = keyByVariantKey[variantKey]
        if let staleCacheKey, staleCacheKey != cacheKey {
            keysByMessageID[messageId]?.remove(staleCacheKey)
        }
        keysByMessageID[messageId, default: []].insert(cacheKey)
        keyByVariantKey[variantKey] = cacheKey
        lock.unlock()

        return staleCacheKey == cacheKey ? nil : staleCacheKey
    }

    /// Called by the cache delegate on eviction; must reach this from a
    /// file-private type, hence `fileprivate`.
    fileprivate func removeTrackedCacheKey(_ cacheKey: String, variantKey: String, for messageId: String) {
        lock.lock()
        defer { lock.unlock() }

        guard var trackedKeys = keysByMessageID[messageId] else { return }
        trackedKeys.remove(cacheKey)

        if trackedKeys.isEmpty {
            keysByMessageID.removeValue(forKey: messageId)
        } else {
            keysByMessageID[messageId] = trackedKeys
        }

        if keyByVariantKey[variantKey] == cacheKey {
            keyByVariantKey.removeValue(forKey: variantKey)
        }
    }

    private func removeTrackedVariantKey(_ variantKey: String, ifMappedTo cacheKey: String) {
        lock.lock()
        defer { lock.unlock() }

        guard keyByVariantKey[variantKey] == cacheKey else {
            return
        }

        keyByVariantKey.removeValue(forKey: variantKey)
    }

#if DEBUG
    /// Number of live (non-evicted) cached variants tracked for `messageId`,
    /// reconciling the index against the live cache as a side effect.
    func variantCount(for messageId: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return syncTrackedCacheKeysWithLiveCache(for: messageId)
    }

    /// Total live cached variants across all tracked messages.
    func totalVariantCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        let messageIDs = Array(keysByMessageID.keys)
        return messageIDs.reduce(0) { $0 + syncTrackedCacheKeysWithLiveCache(for: $1) }
    }

    private func syncTrackedCacheKeysWithLiveCache(for messageId: String) -> Int {
        guard let trackedKeys = keysByMessageID[messageId] else { return 0 }

        let liveKeys = Set(trackedKeys.filter { cache.object(forKey: $0 as NSString) != nil })
        if liveKeys.isEmpty {
            keysByMessageID.removeValue(forKey: messageId)
            return 0
        }

        if liveKeys != trackedKeys {
            keysByMessageID[messageId] = liveKeys
        }

        return liveKeys.count
    }
#endif
}

private final class CachedHTMLLoadResultBox {
    let cacheKey: String
    let variantKey: String
    let messageId: String
    let result: HTMLLoadResult

    init(_ result: HTMLLoadResult, cacheKey: String, variantKey: String, messageId: String) {
        self.cacheKey = cacheKey
        self.variantKey = variantKey
        self.messageId = messageId
        self.result = result
    }
}

private final class HTMLContentCacheDelegate: NSObject, NSCacheDelegate {
    weak var owner: HTMLContentResultCache?

    func cache(_ cache: NSCache<AnyObject, AnyObject>, willEvictObject obj: Any) {
        guard let box = obj as? CachedHTMLLoadResultBox else { return }
        owner?.removeTrackedCacheKey(box.cacheKey, variantKey: box.variantKey, for: box.messageId)
    }
}
