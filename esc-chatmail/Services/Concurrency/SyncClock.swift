import Foundation

/// Abstraction over wall-clock reads and task sleeping so retry/backoff logic
/// can be driven deterministically in tests instead of burning real wall time.
protocol SyncClock: Sendable {
    func now() -> Date
    /// Suspends like `Task.sleep(nanoseconds:)`, including throwing
    /// `CancellationError` when the surrounding task is cancelled.
    func sleep(nanoseconds: UInt64) async throws
}

/// Production clock: real `Date()` and real `Task.sleep`.
struct SystemSyncClock: SyncClock {
    func now() -> Date {
        Date()
    }

    func sleep(nanoseconds: UInt64) async throws {
        try await Task.sleep(nanoseconds: nanoseconds)
    }
}
