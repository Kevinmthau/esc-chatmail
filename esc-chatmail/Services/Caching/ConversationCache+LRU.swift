import Foundation

// MARK: - LRU Management
extension ConversationCache {
    /// Updates access timestamp. The timestamp is already updated via cached.access()
    /// so this is now a no-op. LRU order is determined by lastAccessed timestamps.
    func moveToFront(_ conversationId: String) {
        // No-op: LRU ordering is determined by lastAccessed timestamps in CachedConversation
        // The timestamp is already updated by cached.access() before this is called
    }

    func shouldEvict(newSize: Int) -> Bool {
        return currentMemoryUsage + newSize > maxCacheSize || cache.count >= maxCacheItems
    }

    /// Finds and removes the entry with the oldest lastAccessed timestamp.
    /// This is O(n) but only called during eviction when cache is full.
    func evictLeastRecentlyUsed() {
        guard !cache.isEmpty else { return }

        // Find the conversation with the oldest lastAccessed timestamp
        var lruId: String?
        var oldestTime = Date.distantFuture

        for (id, cached) in cache {
            if cached.lastAccessed < oldestTime {
                oldestTime = cached.lastAccessed
                lruId = id
            }
        }

        if let idToRemove = lruId {
            cache.removeValue(forKey: idToRemove)
            stats.recordEviction()
            updateMemoryUsage()
        }
    }
}
