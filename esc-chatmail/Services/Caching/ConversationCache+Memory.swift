import Foundation
import UIKit
import Combine

// MARK: - Memory Management
extension ConversationCache {
    func setupMemoryWarningObserver() {
        NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)
            .sink { [weak self] _ in
                self?.handleMemoryWarning()
            }
            .store(in: &cancellables)
    }

    func handleMemoryWarning() {
        Log.info("Memory warning received - aggressively clearing conversation cache", category: .general)

        // Clear preloaded HTML first (often the largest memory consumers)
        for cached in cache.values {
            cached.preloadedHTML.removeAll()
        }

        // Aggressively clear 75% of cache on memory warning to free resources
        let itemsToKeep = max(3, cache.count / 4)

        while cache.count > itemsToKeep {
            evictLeastRecentlyUsed()
        }

        Log.info("Cache reduced to \(cache.count) items after memory warning", category: .general)
    }

    func updateMemoryUsage() {
        currentMemoryUsage = cache.values.reduce(0) { $0 + $1.memorySize }
    }
}
