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
        // Aggressively clear cache on memory warning
        let itemsToKeep = min(5, cache.count / 4)

        while cache.count > itemsToKeep {
            evictLeastRecentlyUsed()
        }
    }

    func updateMemoryUsage() {
        currentMemoryUsage = cache.values.reduce(0) { $0 + $1.memorySize }
    }
}
