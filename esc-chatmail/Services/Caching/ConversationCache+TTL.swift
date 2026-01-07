import Foundation
import Combine

// MARK: - TTL Management
extension ConversationCache {
    func startPeriodicCleanup() {
        Timer.publish(every: 60, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                self?.cleanupExpiredItems()
            }
            .store(in: &cancellables)
    }

    func cleanupExpiredItems() {
        let now = Date()
        var expiredIds: [String] = []

        for (id, cached) in cache {
            if now.timeIntervalSince(cached.lastAccessed) > ttl {
                expiredIds.append(id)
            }
        }

        for id in expiredIds {
            invalidate(id)
            stats.recordEviction()
        }
    }
}
