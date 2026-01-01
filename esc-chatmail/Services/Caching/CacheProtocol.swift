import Foundation

// MARK: - Cache Protocol

/// A protocol defining the interface for cache implementations.
/// All cache implementations should conform to this protocol for consistency.
protocol CacheProtocol<Key, Value> {
    associatedtype Key: Hashable & Sendable
    associatedtype Value: Sendable

    /// Retrieves a value from the cache
    func get(_ key: Key) async -> Value?

    /// Stores a value in the cache
    func set(_ key: Key, value: Value) async

    /// Removes a value from the cache
    func remove(_ key: Key) async

    /// Clears all values from the cache
    func clear() async

    /// Prefetches multiple keys (optional optimization)
    func prefetch(_ keys: [Key]) async
}

// MARK: - Cache Configuration

/// Configuration options for cache behavior
struct CacheConfiguration: Sendable {
    /// Maximum number of items to store
    let maxItems: Int

    /// Maximum memory size in bytes (optional)
    let maxMemoryBytes: Int?

    /// Time-to-live for cached items in seconds (optional)
    let ttlSeconds: TimeInterval?

    /// Eviction policy to use when cache is full
    let evictionPolicy: EvictionPolicy

    enum EvictionPolicy: Sendable {
        /// Least Recently Used - evicts items that haven't been accessed recently
        case lru
        /// Time-based LRU - evicts oldest items first, with LRU as tiebreaker
        case timeBasedLRU
    }

    /// Default configuration for general use
    static let `default` = CacheConfiguration(
        maxItems: 100,
        maxMemoryBytes: nil,
        ttlSeconds: nil,
        evictionPolicy: .lru
    )

    init(
        maxItems: Int,
        maxMemoryBytes: Int? = nil,
        ttlSeconds: TimeInterval? = nil,
        evictionPolicy: EvictionPolicy = .lru
    ) {
        self.maxItems = maxItems
        self.maxMemoryBytes = maxMemoryBytes
        self.ttlSeconds = ttlSeconds
        self.evictionPolicy = evictionPolicy
    }
}

// MARK: - LRU Cache Statistics

/// Statistics for monitoring LRU cache performance
struct LRUCacheStatistics: Sendable {
    var hits: Int = 0
    var misses: Int = 0
    var evictions: Int = 0
    var currentItemCount: Int = 0

    var hitRate: Double {
        let total = hits + misses
        guard total > 0 else { return 0 }
        return Double(hits) / Double(total)
    }

    var missRate: Double {
        1.0 - hitRate
    }

    mutating func recordHit() {
        hits += 1
    }

    mutating func recordMiss() {
        misses += 1
    }

    mutating func recordEviction() {
        evictions += 1
    }
}
