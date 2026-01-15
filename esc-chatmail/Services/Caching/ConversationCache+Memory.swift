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
        // Clear half the cache on memory warning (less aggressive to avoid thrashing)
        let itemsToKeep = max(5, cache.count / 2)

        while cache.count > itemsToKeep {
            evictLeastRecentlyUsed()
        }
    }

    func updateMemoryUsage() {
        currentMemoryUsage = cache.values.reduce(0) { $0 + $1.memorySize }
    }
}
