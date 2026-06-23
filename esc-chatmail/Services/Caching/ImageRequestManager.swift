import Foundation
import UIKit

/// Actor for in-flight HTTP image request deduplication.
/// Prevents duplicate network requests for the same URL and tracks failed URLs.
actor ImageRequestManager {
    private var inFlightRequests: [String: Task<UIImage?, Never>] = [:]
    /// Track URLs that have failed to avoid retrying (auto-prunes oldest 20% when full)
    private var failedURLs = BoundedSet<String>(maxSize: 500, prunePercentage: 0.2)

    func loadImage(from urlString: String, onComplete: @escaping (UIImage?) -> Void) async -> UIImage? {
        // Skip URLs that have previously failed
        if failedURLs.contains(urlString) {
            return nil
        }

        // Check for existing in-flight request
        if let existingTask = inFlightRequests[urlString] {
            return await existingTask.value
        }

        // Create new task
        let task = Task<UIImage?, Never> {
            await RemoteImageFetcher.shared.image(from: urlString)
        }

        inFlightRequests[urlString] = task

        let result = await task.value

        // Cache the result or mark as failed
        if result != nil {
            onComplete(result)
        } else {
            // Mark as failed to avoid retrying (until app restart)
            // BoundedSet automatically prunes oldest entries when full
            failedURLs.insert(urlString)
        }

        // Clean up
        inFlightRequests.removeValue(forKey: urlString)

        return result
    }

    /// Clears the failed URL cache (call when network conditions change)
    func clearFailedURLs() {
        failedURLs.removeAll()
    }
}
