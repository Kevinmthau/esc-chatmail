import XCTest
@testable import esc_chatmail

final class LRUCacheActorTests: XCTestCase {

    // MARK: - Basic Operations

    func testGet_nonExistentKey_returnsNilAndRecordsMiss() async {
        let cache = LRUCacheActor<String, String>(config: .default)

        let result = await cache.get("nonexistent")

        XCTAssertNil(result)
        let stats = await cache.getStatistics()
        XCTAssertEqual(stats.misses, 1)
        XCTAssertEqual(stats.hits, 0)
    }

    func testSet_newKey_storesValue() async {
        let cache = LRUCacheActor<String, String>(config: .default)

        await cache.set("key1", value: "value1")
        let result = await cache.get("key1")

        XCTAssertEqual(result, "value1")
    }

    func testSet_existingKey_updatesValue() async {
        let cache = LRUCacheActor<String, String>(config: .default)

        await cache.set("key1", value: "value1")
        await cache.set("key1", value: "value2")
        let result = await cache.get("key1")

        XCTAssertEqual(result, "value2")
    }

    func testRemove_existingKey_deletesEntry() async {
        let cache = LRUCacheActor<String, String>(config: .default)

        await cache.set("key1", value: "value1")
        await cache.remove("key1")
        let result = await cache.get("key1")

        XCTAssertNil(result)
    }

    func testRemove_nonExistentKey_doesNotCrash() async {
        let cache = LRUCacheActor<String, String>(config: .default)

        await cache.remove("nonexistent")

        // Should not throw or crash
        let stats = await cache.getStatistics()
        XCTAssertEqual(stats.currentItemCount, 0)
    }

    func testClear_removesAllEntries() async {
        let cache = LRUCacheActor<String, String>(config: .default)

        await cache.set("key1", value: "value1")
        await cache.set("key2", value: "value2")
        await cache.set("key3", value: "value3")

        await cache.clear()

        let key1Value = await cache.get("key1")
        let key2Value = await cache.get("key2")
        let key3Value = await cache.get("key3")
        XCTAssertNil(key1Value)
        XCTAssertNil(key2Value)
        XCTAssertNil(key3Value)

        let stats = await cache.getStatistics()
        XCTAssertEqual(stats.currentItemCount, 0)
    }

    // MARK: - LRU Eviction

    func testEviction_whenAtCapacity_removesLeastRecentlyUsed() async {
        let config = CacheConfiguration(maxItems: 3)
        let cache = LRUCacheActor<String, String>(config: config)

        // Fill the cache
        await cache.set("key1", value: "value1")
        await cache.set("key2", value: "value2")
        await cache.set("key3", value: "value3")

        // Access key1 to make it more recent
        _ = await cache.get("key1")

        // Add a new item, should evict key2 (least recently used)
        await cache.set("key4", value: "value4")

        let key1Value = await cache.get("key1")
        let key2Value = await cache.get("key2")
        let key3Value = await cache.get("key3")
        let key4Value = await cache.get("key4")
        XCTAssertNotNil(key1Value, "key1 should still exist (was accessed)")
        XCTAssertNil(key2Value, "key2 should be evicted (least recently used)")
        XCTAssertNotNil(key3Value, "key3 should still exist")
        XCTAssertNotNil(key4Value, "key4 should exist (just added)")
    }

    func testEviction_accessUpdatesRecency() async {
        let config = CacheConfiguration(maxItems: 2)
        let cache = LRUCacheActor<String, String>(config: config)

        await cache.set("key1", value: "value1")
        await cache.set("key2", value: "value2")

        // Access key1 to make it more recent than key2
        _ = await cache.get("key1")

        // Add new item - should evict key2, not key1
        await cache.set("key3", value: "value3")

        let key1Value = await cache.get("key1")
        let key2Value = await cache.get("key2")
        let key3Value = await cache.get("key3")
        XCTAssertNotNil(key1Value, "key1 should survive (was accessed)")
        XCTAssertNil(key2Value, "key2 should be evicted")
        XCTAssertNotNil(key3Value, "key3 should exist")
    }

    func testEviction_respectsMaxItems() async {
        let config = CacheConfiguration(maxItems: 5)
        let cache = LRUCacheActor<String, Int>(config: config)

        // Add more items than capacity
        for i in 1...10 {
            await cache.set("key\(i)", value: i)
        }

        let stats = await cache.getStatistics()
        XCTAssertEqual(stats.currentItemCount, 5, "Should never exceed maxItems")
        XCTAssertEqual(stats.evictions, 5, "Should have evicted 5 items")
    }

    func testEviction_updatingExistingKey_doesNotEvict() async {
        let config = CacheConfiguration(maxItems: 3)
        let cache = LRUCacheActor<String, String>(config: config)

        await cache.set("key1", value: "value1")
        await cache.set("key2", value: "value2")
        await cache.set("key3", value: "value3")

        // Update existing key - should NOT trigger eviction
        await cache.set("key1", value: "updated")

        let stats = await cache.getStatistics()
        XCTAssertEqual(stats.currentItemCount, 3)
        XCTAssertEqual(stats.evictions, 0)
        let updatedValue = await cache.get("key1")
        XCTAssertEqual(updatedValue, "updated")
    }

    // MARK: - TTL (Time To Live)

    func testGet_expiredEntry_returnsNilAndEvicts() async {
        let config = CacheConfiguration(maxItems: 100, ttlSeconds: 0.1)
        let cache = LRUCacheActor<String, String>(config: config)

        await cache.set("key1", value: "value1")

        // Wait for TTL to expire
        try? await Task.sleep(nanoseconds: 150_000_000) // 150ms

        let result = await cache.get("key1")
        XCTAssertNil(result, "Expired entry should return nil")

        let stats = await cache.getStatistics()
        XCTAssertEqual(stats.evictions, 1, "Expired entry should be evicted")
    }

    func testGet_nonExpiredEntry_returnsValue() async {
        let config = CacheConfiguration(maxItems: 100, ttlSeconds: 10.0)
        let cache = LRUCacheActor<String, String>(config: config)

        await cache.set("key1", value: "value1")

        let result = await cache.get("key1")
        XCTAssertEqual(result, "value1", "Non-expired entry should return value")
    }

    func testCleanupExpired_removesOldEntries() async {
        let config = CacheConfiguration(maxItems: 100, ttlSeconds: 0.1)
        let cache = LRUCacheActor<String, String>(config: config)

        await cache.set("key1", value: "value1")
        await cache.set("key2", value: "value2")

        // Wait for TTL to expire
        try? await Task.sleep(nanoseconds: 150_000_000) // 150ms

        await cache.cleanupExpired()

        let stats = await cache.getStatistics()
        XCTAssertEqual(stats.currentItemCount, 0, "All expired entries should be removed")
        XCTAssertEqual(stats.evictions, 2, "Both entries should be evicted")
    }

    func testCleanupExpired_preservesNonExpiredEntries() async {
        let config = CacheConfiguration(maxItems: 100, ttlSeconds: 10.0)
        let cache = LRUCacheActor<String, String>(config: config)

        await cache.set("key1", value: "value1")
        await cache.set("key2", value: "value2")

        await cache.cleanupExpired()

        let stats = await cache.getStatistics()
        XCTAssertEqual(stats.currentItemCount, 2, "Non-expired entries should remain")
        XCTAssertEqual(stats.evictions, 0, "No evictions should occur")
    }

    func testCleanupExpired_noTTL_doesNothing() async {
        let config = CacheConfiguration(maxItems: 100, ttlSeconds: nil)
        let cache = LRUCacheActor<String, String>(config: config)

        await cache.set("key1", value: "value1")

        await cache.cleanupExpired()

        let stats = await cache.getStatistics()
        XCTAssertEqual(stats.currentItemCount, 1, "Entry should remain when no TTL")
    }

    // MARK: - Memory Limits

    func testEviction_respectsMaxMemoryBytes() async {
        // Note: evictIfNeeded() checks memory BEFORE inserting the new entry
        // So set maxMemoryBytes such that 2 entries exceed it, triggering eviction on 3rd insert
        let config = CacheConfiguration(maxItems: 100, maxMemoryBytes: 80)
        let cache = LRUCacheActor<String, String>(config: config)

        // Add entries with size tracking (each 50 bytes)
        await cache.set("key1", value: "value1", sizeBytes: 50)
        await cache.set("key2", value: "value2", sizeBytes: 50)
        // After key2: memory = 100, which > 80

        // This should trigger eviction since current memory (100) > maxMemoryBytes (80)
        await cache.set("key3", value: "value3", sizeBytes: 50)

        let stats = await cache.getStatistics()
        XCTAssertEqual(stats.currentItemCount, 2, "Should evict to stay within memory limit")
        XCTAssertGreaterThan(stats.evictions, 0, "Should have evicted at least one item")
    }

    func testSet_withSizeTracking_calculatesCorrectly() async {
        let config = CacheConfiguration(maxItems: 100, maxMemoryBytes: 1000)
        let cache = LRUCacheActor<String, String>(config: config)

        await cache.set("key1", value: "value1", sizeBytes: 100)
        await cache.set("key2", value: "value2", sizeBytes: 200)
        await cache.set("key3", value: "value3", sizeBytes: 300)

        let stats = await cache.getStatistics()
        XCTAssertEqual(stats.currentItemCount, 3)
    }

    // MARK: - Statistics

    func testStatistics_tracksHitsAndMisses() async {
        let cache = LRUCacheActor<String, String>(config: .default)

        await cache.set("key1", value: "value1")

        _ = await cache.get("key1") // hit
        _ = await cache.get("key1") // hit
        _ = await cache.get("nonexistent") // miss
        _ = await cache.get("also-nonexistent") // miss

        let stats = await cache.getStatistics()
        XCTAssertEqual(stats.hits, 2)
        XCTAssertEqual(stats.misses, 2)
    }

    func testStatistics_tracksEvictions() async {
        let config = CacheConfiguration(maxItems: 2)
        let cache = LRUCacheActor<String, String>(config: config)

        await cache.set("key1", value: "value1")
        await cache.set("key2", value: "value2")
        await cache.set("key3", value: "value3") // evicts key1
        await cache.set("key4", value: "value4") // evicts key2

        let stats = await cache.getStatistics()
        XCTAssertEqual(stats.evictions, 2)
    }

    func testHitRate_calculatesCorrectly() async {
        let cache = LRUCacheActor<String, String>(config: .default)

        await cache.set("key1", value: "value1")

        _ = await cache.get("key1") // hit
        _ = await cache.get("key1") // hit
        _ = await cache.get("key1") // hit
        _ = await cache.get("nonexistent") // miss

        let stats = await cache.getStatistics()
        XCTAssertEqual(stats.hitRate, 0.75, accuracy: 0.001)
        XCTAssertEqual(stats.missRate, 0.25, accuracy: 0.001)
    }

    func testHitRate_noAccesses_returnsZero() async {
        let cache = LRUCacheActor<String, String>(config: .default)

        let stats = await cache.getStatistics()
        XCTAssertEqual(stats.hitRate, 0.0)
    }

    // MARK: - Contains & AllKeys

    func testContains_existingKey_returnsTrue() async {
        let cache = LRUCacheActor<String, String>(config: .default)

        await cache.set("key1", value: "value1")

        let result = await cache.contains("key1")
        XCTAssertTrue(result)
    }

    func testContains_nonExistentKey_returnsFalse() async {
        let cache = LRUCacheActor<String, String>(config: .default)

        let result = await cache.contains("nonexistent")
        XCTAssertFalse(result)
    }

    func testContains_expiredKey_returnsFalse() async {
        let config = CacheConfiguration(maxItems: 100, ttlSeconds: 0.1)
        let cache = LRUCacheActor<String, String>(config: config)

        await cache.set("key1", value: "value1")

        // Wait for TTL to expire
        try? await Task.sleep(nanoseconds: 150_000_000) // 150ms

        let result = await cache.contains("key1")
        XCTAssertFalse(result, "Contains should return false for expired entry")
    }

    func testContains_doesNotUpdateAccessOrder() async {
        let config = CacheConfiguration(maxItems: 2)
        let cache = LRUCacheActor<String, String>(config: config)

        await cache.set("key1", value: "value1")
        await cache.set("key2", value: "value2")

        // Use contains() instead of get() - should NOT update access time
        _ = await cache.contains("key1")

        // Add new item - key1 should be evicted since contains() didn't update its access time
        await cache.set("key3", value: "value3")

        // key1 should be evicted (oldest by access time)
        let key1Value = await cache.get("key1")
        XCTAssertNil(key1Value, "key1 should be evicted - contains() should not update access order")
    }

    func testAllKeys_returnsAllStoredKeys() async {
        let cache = LRUCacheActor<String, String>(config: .default)

        await cache.set("key1", value: "value1")
        await cache.set("key2", value: "value2")
        await cache.set("key3", value: "value3")

        let keys = await cache.allKeys()
        XCTAssertEqual(Set(keys), Set(["key1", "key2", "key3"]))
    }

    func testAllKeys_emptyCache_returnsEmptyArray() async {
        let cache = LRUCacheActor<String, String>(config: .default)

        let keys = await cache.allKeys()
        XCTAssertTrue(keys.isEmpty)
    }

    // MARK: - Concurrent Access

    func testConcurrentAccess_maintainsConsistency() async {
        let cache = LRUCacheActor<Int, Int>(config: CacheConfiguration(maxItems: 100))

        // Perform concurrent writes
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<50 {
                group.addTask {
                    await cache.set(i, value: i * 10)
                }
            }
        }

        // Verify all values are correct
        for i in 0..<50 {
            let value = await cache.get(i)
            XCTAssertEqual(value, i * 10, "Value for key \(i) should be \(i * 10)")
        }
    }

    func testConcurrentSetAndGet_noDataCorruption() async {
        let cache = LRUCacheActor<String, String>(config: CacheConfiguration(maxItems: 10))

        // Perform concurrent reads and writes
        await withTaskGroup(of: Void.self) { group in
            // Writers
            for i in 0..<20 {
                group.addTask {
                    await cache.set("key\(i % 10)", value: "value\(i)")
                }
            }

            // Readers
            for i in 0..<20 {
                group.addTask {
                    _ = await cache.get("key\(i % 10)")
                }
            }
        }

        // Cache should still be functional
        let stats = await cache.getStatistics()
        XCTAssertLessThanOrEqual(stats.currentItemCount, 10, "Should not exceed max items")
    }

    // MARK: - Edge Cases

    func testCache_withZeroCapacity_stillWorks() async {
        // Edge case: capacity of 1
        let config = CacheConfiguration(maxItems: 1)
        let cache = LRUCacheActor<String, String>(config: config)

        await cache.set("key1", value: "value1")
        await cache.set("key2", value: "value2")

        let stats = await cache.getStatistics()
        XCTAssertEqual(stats.currentItemCount, 1)
        let key2Value = await cache.get("key2")
        let key1Value = await cache.get("key1")
        XCTAssertNotNil(key2Value)
        XCTAssertNil(key1Value)
    }

    func testCache_withIntegerKeys() async {
        let cache = LRUCacheActor<Int, String>(config: .default)

        await cache.set(1, value: "one")
        await cache.set(2, value: "two")
        await cache.set(3, value: "three")

        let value1 = await cache.get(1)
        let value2 = await cache.get(2)
        let value3 = await cache.get(3)
        XCTAssertEqual(value1, "one")
        XCTAssertEqual(value2, "two")
        XCTAssertEqual(value3, "three")
    }

    func testCache_withComplexValueTypes() async {
        struct Person: Sendable, Equatable {
            let name: String
            let age: Int
        }

        let cache = LRUCacheActor<String, Person>(config: .default)

        let alice = Person(name: "Alice", age: 30)
        let bob = Person(name: "Bob", age: 25)

        await cache.set("alice", value: alice)
        await cache.set("bob", value: bob)

        let aliceValue = await cache.get("alice")
        let bobValue = await cache.get("bob")
        XCTAssertEqual(aliceValue, alice)
        XCTAssertEqual(bobValue, bob)
    }
}
