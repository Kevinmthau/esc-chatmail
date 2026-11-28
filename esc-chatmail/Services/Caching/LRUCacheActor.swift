import Foundation

/// A generic LRU (Least Recently Used) cache implemented as an actor for thread safety.
/// Supports configurable capacity, optional TTL, and automatic eviction.
actor LRUCacheActor<Key: Hashable & Sendable, Value: Sendable>: CacheProtocol {

    // MARK: - Cache Entry

    private struct CacheEntry {
        let value: Value
        let createdAt: Date
        /// Monotonic access order used for LRU eviction.
        /// Using a sequence avoids `Date()` tie flakiness (multiple accesses within the same clock tick).
        var lastAccessSequence: UInt64
        let sizeBytes: Int?

        var age: TimeInterval {
            Date().timeIntervalSince(createdAt)
        }

        init(value: Value, accessSequence: UInt64, sizeBytes: Int? = nil) {
            let now = Date()
            self.value = value
            self.createdAt = now
            self.lastAccessSequence = accessSequence
            self.sizeBytes = sizeBytes
        }
    }

    // MARK: - Properties

    private var storage: [Key: CacheEntry] = [:]
    /// The sum of every stored entry's `sizeBytes`, kept with `storage` at each insert and
    /// removal so the budget is not summed again at every eviction.
    private var storedBytes = 0
    private let config: CacheConfiguration
    private var stats = LRUCacheStatistics()
    private var accessSequenceCounter: UInt64 = 0

    // Note: LRU ordering is determined by a monotonic sequence number in CacheEntry,
    // avoiding `Date()` tie ambiguity while keeping O(1) access updates.

    // MARK: - Initialization

    init(config: CacheConfiguration = .default) {
        self.config = config
    }

    // MARK: - CacheProtocol Implementation

    func get(_ key: Key) async -> Value? {
        guard var entry = storage[key] else {
            stats.recordMiss()
            return nil
        }

        // Check TTL if configured
        if let ttl = config.ttlSeconds, entry.age > ttl {
            removeEntry(forKey: key)
            stats.recordMiss()
            stats.recordEviction()
            return nil
        }

        // Update access order (O(1))
        accessSequenceCounter &+= 1
        entry.lastAccessSequence = accessSequenceCounter
        storage[key] = entry

        stats.recordHit()
        return entry.value
    }

    func set(_ key: Key, value: Value) async {
        set(key, value: value, sizeBytes: nil)
    }

    func remove(_ key: Key) async {
        removeEntry(forKey: key)
        stats.currentItemCount = storage.count
    }

    func clear() async {
        storage.removeAll()
        storedBytes = 0
        stats.currentItemCount = 0
    }

    func prefetch(_ keys: [Key]) async {
        // Default implementation does nothing
        // Subclasses can override to implement prefetching logic
    }

    // MARK: - Extended API

    /// Sets a value with optional size tracking for memory-based eviction.
    ///
    /// The entry is stored first and the limits are then met by evicting the least recently
    /// used entries other than this one: the cache never holds more than its budget after an
    /// insert, as it did when the check ran before it, and an entry larger than the whole
    /// budget stays, alone, rather than evicting itself and everything else (architecture
    /// review 2026-11, caching-memory#1).
    func set(_ key: Key, value: Value, sizeBytes: Int?) {
        accessSequenceCounter &+= 1
        let entry = CacheEntry(value: value, accessSequence: accessSequenceCounter, sizeBytes: sizeBytes)
        removeEntry(forKey: key)
        storage[key] = entry
        storedBytes += max(0, sizeBytes ?? 0)
        fitWithinLimits(sparing: key)
        stats.currentItemCount = storage.count
    }

    /// Returns current cache statistics
    func getStatistics() -> LRUCacheStatistics {
        var currentStats = stats
        currentStats.currentItemCount = storage.count
        return currentStats
    }

    /// Checks if a key exists in the cache (without updating access order)
    func contains(_ key: Key) -> Bool {
        guard let entry = storage[key] else { return false }

        // Check TTL if configured
        if let ttl = config.ttlSeconds, entry.age > ttl {
            return false
        }

        return true
    }

    /// Returns all keys currently in the cache
    func allKeys() -> [Key] {
        Array(storage.keys)
    }

    /// Removes expired entries based on TTL
    func cleanupExpired() {
        guard let ttl = config.ttlSeconds else { return }

        let now = Date()
        var keysToRemove: [Key] = []

        for (key, entry) in storage {
            if now.timeIntervalSince(entry.createdAt) > ttl {
                keysToRemove.append(key)
            }
        }

        for key in keysToRemove {
            removeEntry(forKey: key)
            stats.recordEviction()
        }

        stats.currentItemCount = storage.count
    }

    // MARK: - Private Helpers

    /// Evicts least recently used entries, never `keptKey`, until the item count and the
    /// byte budget both hold, or `keptKey` is all that is left.
    private func fitWithinLimits(sparing keptKey: Key) {
        while storage.count > config.maxItems || isOverByteBudget {
            guard evictLeastRecentlyUsed(sparing: keptKey) else { return }
        }
    }

    private var isOverByteBudget: Bool {
        guard let maxBytes = config.maxMemoryBytes else { return false }
        return storedBytes > maxBytes
    }

    /// Finds and removes the entry other than `keptKey` with the oldest access sequence; false
    /// when there is none. O(n), and only called when the cache is over a limit.
    private func evictLeastRecentlyUsed(sparing keptKey: Key) -> Bool {
        // Find the key with the oldest access sequence (deterministic).
        var lruKey: Key?
        var oldestSequence = UInt64.max

        for (key, entry) in storage where key != keptKey {
            if entry.lastAccessSequence < oldestSequence {
                oldestSequence = entry.lastAccessSequence
                lruKey = key
            }
        }

        guard let keyToRemove = lruKey else { return false }
        removeEntry(forKey: keyToRemove)
        stats.recordEviction()
        stats.currentItemCount = storage.count
        return true
    }

    /// Removes an entry and its bytes from the running total.
    private func removeEntry(forKey key: Key) {
        guard let removed = storage.removeValue(forKey: key) else { return }
        storedBytes -= max(0, removed.sizeBytes ?? 0)
    }
}
