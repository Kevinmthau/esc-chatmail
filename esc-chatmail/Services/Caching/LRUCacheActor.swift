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
    private var accessOrder: [Key] = []
    private let config: CacheConfiguration
    private var stats = LRUCacheStatistics()

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
            removeFromAccessOrder(key)
            stats.recordMiss()
            stats.recordEviction()
            return nil
        }

        // Update access time and order
        entry.lastAccessedAt = Date()
        storage[key] = entry
        updateAccessOrder(for: key)

        stats.recordHit()
        return entry.value
    }

    func set(_ key: Key, value: Value) async {
        set(key, value: value, sizeBytes: nil)
    }

    func remove(_ key: Key) async {
        storage.removeValue(forKey: key)
        removeFromAccessOrder(key)
        stats.currentItemCount = storage.count
    }

    func clear() async {
        storage.removeAll()
        accessOrder.removeAll()
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

        // If key already exists, update it
        if storage[key] != nil {
            storage[key] = entry
            updateAccessOrder(for: key)
        } else {
            // New entry - may need to evict
            evictIfNeeded()
            storage[key] = entry
            accessOrder.append(key)
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
            removeFromAccessOrder(key)
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
            while currentMemoryUsage() > maxBytes && !accessOrder.isEmpty {
                evictLeastRecentlyUsed()
            }
        }
    }

    private func evictLeastRecentlyUsed() {
        guard let lruKey = accessOrder.first else { return }
        storage.removeValue(forKey: lruKey)
        accessOrder.removeFirst()
        stats.recordEviction()
        stats.currentItemCount = storage.count
    }

    private func updateAccessOrder(for key: Key) {
        removeFromAccessOrder(key)
        accessOrder.append(key)
    }

    private func removeFromAccessOrder(_ key: Key) {
        if let index = accessOrder.firstIndex(of: key) {
            accessOrder.remove(at: index)
        }
    }

    private func currentMemoryUsage() -> Int {
        storage.values.compactMap(\.sizeBytes).reduce(0, +)
    }
}
