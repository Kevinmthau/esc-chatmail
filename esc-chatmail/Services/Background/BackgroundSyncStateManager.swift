import Foundation
import os

/// Owns background retry backoff and removes checkpoints left by the retired
/// delta writer. The model-v3 executor owns current cursor/checkpoint writes.
final class BackgroundSyncStateManager {
    private enum DefaultsKeys {
        static let continuationState = "backgroundSync.continuationState"
    }

    private struct RetryState {
        var retryCount = 0
        var backoff: TimeInterval
    }

    private let retryState: OSAllocatedUnfairLock<RetryState>
    private let maxRetries: Int
    private let initialBackoffSeconds: TimeInterval
    private let maxBackoffSeconds: TimeInterval

    init(
        maxRetries: Int = 3,
        initialBackoffSeconds: TimeInterval = 30,
        maxBackoffSeconds: TimeInterval = 3600
    ) {
        self.maxRetries = maxRetries
        self.initialBackoffSeconds = initialBackoffSeconds
        self.maxBackoffSeconds = maxBackoffSeconds
        self.retryState = OSAllocatedUnfairLock(initialState: RetryState(backoff: initialBackoffSeconds))
    }

    /// Upgrades and account teardown must still discard the old checkpoint,
    /// including malformed data, even though new runs never read or write it.
    static func clearContinuationState(in defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: DefaultsKeys.continuationState)
    }

    /// Increments retry count and returns whether we should retry
    /// Returns the backoff interval if we should retry, nil if we've exceeded max retries
    func incrementRetryAndGetBackoff() -> TimeInterval? {
        retryState.withLock { state in
            state.retryCount += 1

            if state.retryCount >= maxRetries {
                state.retryCount = 0
                state.backoff = initialBackoffSeconds
                return nil
            } else {
                state.backoff = min(state.backoff * 2, maxBackoffSeconds)
                return state.backoff
            }
        }
    }

    /// Resets retry count and backoff to initial values
    func resetRetryCount() {
        retryState.withLock { state in
            state.retryCount = 0
            state.backoff = initialBackoffSeconds
        }
    }
}
