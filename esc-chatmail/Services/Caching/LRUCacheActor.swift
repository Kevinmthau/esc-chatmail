import Foundation

/// A generic LRU (Least Recently Used) cache implemented as an actor for thread safety.
/// Supports configurable capacity, optional TTL, and automatic eviction.
actor LRUCacheActor<Key: Hashable & Sendable, Value: Sendable>: CacheProtocol {

    // MARK: - Cache Entry

    private struct CacheEntry {
        let value: Value
        let createdAt: Date
        var lastAccessedAt: Date
        let sizeBytes: Int?

        var age: TimeInterval {
            Date().timeIntervalSince(createdAt)
        }

        init(value: Value, sizeBytes: Int? = nil) {
            let now = Date()
            self.value = value
            self.createdAt = now
            self.lastAccessedAt = now
            self.sizeBytes = sizeBytes
        }
    }

    // MARK: - Properties

    private var storage: [Key: CacheEntry] = [:]
    private let config: CacheConfiguration
    private var stats = LRUCacheStatistics()

    // Note: LRU ordering is determined by lastAccessedAt timestamps in CacheEntry,
    // eliminating the O(n) array operations that were previously required for every access.

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
            storage.removeValue(forKey: key)
            stats.recordMiss()
            stats.recordEviction()
            return nil
        }

        // Update access time (O(1) - timestamp determines LRU order)
        entry.lastAccessedAt = Date()
        storage[key] = entry

        stats.recordHit()
        return entry.value
    }

    func set(_ key: Key, value: Value) async {
        set(key, value: value, sizeBytes: nil)
    }

    func remove(_ key: Key) async {
        storage.removeValue(forKey: key)
        stats.currentItemCount = storage.count
    }

    func clear() async {
        storage.removeAll()
        stats.currentItemCount = 0
    }

    func prefetch(_ keys: [Key]) async {
        // Default implementation does nothing
        // Subclasses can override to implement prefetching logic
    }

    // MARK: - Extended API

    /// Sets a value with optional size tracking for memory-based eviction
    func set(_ key: Key, value: Value, sizeBytes: Int?) {
        let entry = CacheEntry(value: value, sizeBytes: sizeBytes)

        // If key already exists, just update it (O(1))
        if storage[key] != nil {
            storage[key] = entry
        } else {
            // New entry - may need to evict first
            evictIfNeeded()
            storage[key] = entry
        }

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
            storage.removeValue(forKey: key)
            stats.recordEviction()
        }

        stats.currentItemCount = storage.count
    }

    // MARK: - Private Helpers

    private func evictIfNeeded() {
        // Check item count limit
        while storage.count >= config.maxItems {
            evictLeastRecentlyUsed()
        }

        // Check memory limit if configured
        if let maxBytes = config.maxMemoryBytes {
            while currentMemoryUsage() > maxBytes && !storage.isEmpty {
                evictLeastRecentlyUsed()
            }
        }
    }

    /// Finds and removes the entry with the oldest lastAccessedAt timestamp.
    /// This is O(n) but only called during eviction when cache is full.
    private func evictLeastRecentlyUsed() {
        guard !storage.isEmpty else { return }

        // Find the key with the oldest lastAccessedAt timestamp
        var lruKey: Key?
        var oldestTime = Date.distantFuture

        for (key, entry) in storage {
            if entry.lastAccessedAt < oldestTime {
                oldestTime = entry.lastAccessedAt
                lruKey = key
            }
        }

        if let keyToRemove = lruKey {
            storage.removeValue(forKey: keyToRemove)
            stats.recordEviction()
            stats.currentItemCount = storage.count
        }
    }

    private func currentMemoryUsage() -> Int {
        storage.values.compactMap(\.sizeBytes).reduce(0, +)
    }
}
