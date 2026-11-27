import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Actor for in-flight HTTP image request deduplication.
/// Prevents duplicate network requests for the same URL and remembers failed URLs.
actor ImageRequestManager {
    private var inFlightRequests: [String: Task<RemoteImageFetchOutcome, Never>] = [:]
    /// URLs that will not yield an image (`RemoteImageFetchOutcome.definitiveFailure`),
    /// remembered for the process; auto-prunes the oldest 20% when full.
    private var failedURLs = BoundedSet<String>(maxSize: 500, prunePercentage: 0.2)
    /// URLs whose last fetch failed for now, with when: refused until
    /// `transientFailureRetryInterval` has passed, then fetched again. Until 2026-11-27
    /// every failure went into `failedURLs`, so one offline or timed-out view left a
    /// card's hero image or a Drive thumbnail a placeholder until the process ended, days
    /// on the Mac (architecture review 2026-11, networking#6, caching-memory#2). A time
    /// and not a reconnect hook: `AppNetworkMonitor`'s one connectivity callback belongs
    /// to the pending-action queue. Bounded like `failedURLs`: past
    /// `maxTransientFailures` the oldest entry goes.
    private var transientFailures: [String: Date] = [:]
    private let transientFailureRetryInterval: TimeInterval
    private let now: @Sendable () -> Date
    private let imageFetcher: any RemoteImageFetching
    private let remoteConfig: any RemoteConfigProvider

    private static let maxTransientFailures = 500

    init(
        imageFetcher: any RemoteImageFetching = RemoteImageFetcher.shared,
        remoteConfig: any RemoteConfigProvider = StaticRemoteConfigProvider.shared,
        transientFailureRetryInterval: TimeInterval = 30,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.imageFetcher = imageFetcher
        self.remoteConfig = remoteConfig
        self.transientFailureRetryInterval = transientFailureRetryInterval
        self.now = now
    }

    func loadImage(from urlString: String, onComplete: @escaping (PlatformImage?) -> Void) async -> PlatformImage? {
        guard await remoteConfig.isEnabled(.remoteImageLoadingEnabled) else {
            return nil
        }

        // Skip URLs that will not yield an image, and those that failed too recently.
        if failedURLs.contains(urlString) {
            return nil
        }
        if let failedAt = transientFailures[urlString] {
            guard now().timeIntervalSince(failedAt) >= transientFailureRetryInterval else {
                return nil
            }
            transientFailures.removeValue(forKey: urlString)
        }

        // Check for existing in-flight request
        if let existingTask = inFlightRequests[urlString] {
            return Self.image(of: await existingTask.value)
        }

        // Create new task
        let imageFetcher = imageFetcher
        let task = Task<RemoteImageFetchOutcome, Never> {
            await imageFetcher.fetchImage(from: urlString)
        }

        inFlightRequests[urlString] = task

        let outcome = await task.value
        let result = Self.image(of: outcome)

        switch outcome {
        case .image(let image):
            onComplete(image)
        case .definitiveFailure:
            // Re-checked, as before: a load that remote config switched off while it was
            // in flight is never remembered as a failure.
            if await remoteConfig.isEnabled(.remoteImageLoadingEnabled) {
                failedURLs.insert(urlString)
            }
        case .transientFailure:
            if await remoteConfig.isEnabled(.remoteImageLoadingEnabled) {
                rememberTransientFailure(of: urlString)
            }
        case .disabled:
            break
        }

        // Clean up
        inFlightRequests.removeValue(forKey: urlString)

        return result
    }

    /// Forgets both kinds of failure. Called when the caches are cleared
    /// (`EnhancedImageCache.clearAll`, a sign-out); it had no caller before 2026-11-27.
    func clearFailedURLs() {
        failedURLs.removeAll()
        transientFailures.removeAll()
    }

    private func rememberTransientFailure(of urlString: String) {
        if transientFailures[urlString] == nil, transientFailures.count >= Self.maxTransientFailures,
           let oldest = transientFailures.min(by: { $0.value < $1.value }) {
            transientFailures.removeValue(forKey: oldest.key)
        }
        transientFailures[urlString] = now()
    }

    private static func image(of outcome: RemoteImageFetchOutcome) -> PlatformImage? {
        if case .image(let image) = outcome {
            return image
        }
        return nil
    }
}
