import Foundation
import UIKit

/// Actor for in-flight HTTP image request deduplication.
/// Prevents duplicate network requests for the same URL and tracks failed URLs.
actor ImageRequestManager {
    private var inFlightRequests: [String: Task<UIImage?, Never>] = [:]
    private var failedURLs: Set<String> = []  // Track URLs that have failed to avoid retrying

    /// Maximum number of failed URLs to track before pruning
    private let maxFailedURLs = 500

    /// Validates that a URL string is a valid HTTP/HTTPS URL
    private func isValidImageURL(_ urlString: String) -> Bool {
        guard let url = URL(string: urlString),
              let scheme = url.scheme?.lowercased(),
              (scheme == "http" || scheme == "https"),
              let host = url.host, !host.isEmpty else {
            return false
        }
        return true
    }

    func loadImage(from urlString: String, onComplete: @escaping (UIImage?) -> Void) async -> UIImage? {
        // Skip URLs that have previously failed
        if failedURLs.contains(urlString) {
            return nil
        }

        // Validate URL before attempting to load
        guard isValidImageURL(urlString) else {
            // Silently skip invalid URLs - don't log as these are expected for missing avatars
            return nil
        }

        // Check for existing in-flight request
        if let existingTask = inFlightRequests[urlString] {
            return await existingTask.value
        }

        // Create new task
        let task = Task<UIImage?, Never> {
            guard let url = URL(string: urlString) else { return nil }

            do {
                // Create a request with HTTP/3 disabled to avoid QUIC errors
                var request = URLRequest(url: url)
                request.timeoutInterval = 15.0
                if #available(iOS 14.5, *) {
                    request.assumesHTTP3Capable = false
                }

                let (data, response) = try await URLSession.shared.data(for: request)

                // Check for valid HTTP response
                guard let httpResponse = response as? HTTPURLResponse,
                      (200...299).contains(httpResponse.statusCode) else {
                    return nil
                }

                // Try to decode the image
                if let image = UIImage(data: data) {
                    return image
                }

                // If UIImage fails, it might be AVIF or another unsupported format
                // This is expected for some Google profile pictures
                return nil
            } catch {
                // Only log unexpected errors, not common network issues
                let nsError = error as NSError
                if nsError.code != NSURLErrorCancelled &&
                   nsError.code != NSURLErrorTimedOut &&
                   nsError.code != NSURLErrorNotConnectedToInternet {
                    // Log at debug level - image loading failures are non-critical
                    Log.debug("Image load failed for \(url.host ?? "unknown"): \(error.localizedDescription)", category: .general)
                }
                return nil
            }
        }

        inFlightRequests[urlString] = task

        let result = await task.value

        // Cache the result or mark as failed
        if result != nil {
            onComplete(result)
        } else {
            // Mark as failed to avoid retrying (until app restart)
            // Prune oldest entries if we exceed the limit
            if failedURLs.count >= maxFailedURLs {
                // Remove ~20% of entries when limit reached
                let removeCount = maxFailedURLs / 5
                for _ in 0..<removeCount {
                    if let first = failedURLs.first {
                        failedURLs.remove(first)
                    }
                }
            }
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
