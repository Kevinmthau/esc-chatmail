import Foundation

// MARK: - LRU Management
extension ConversationCache {
    func moveToFront(_ conversationId: String) {
        lruOrder.removeAll { $0 == conversationId }
        lruOrder.insert(conversationId, at: 0)
    }

    func shouldEvict(newSize: Int) -> Bool {
        return currentMemoryUsage + newSize > maxCacheSize || cache.count >= maxCacheItems
    }

    func evictLeastRecentlyUsed() {
        guard let lruId = lruOrder.last else { return }

        cache.removeValue(forKey: lruId)
        lruOrder.removeLast()
        stats.recordEviction()

        updateMemoryUsage()
    }
}
