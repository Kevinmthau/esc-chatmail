import Foundation

/// Protocol for types that perform periodic cleanup
protocol PeriodicCleanupHandler: AnyObject, Sendable {
    /// Performs cleanup operation
    func performCleanup() async
}

/// Encapsulates a periodic cleanup task pattern used by disk caches.
/// Handles the Task lifecycle including sleep, cleanup invocation, and cancellation.
///
/// Usage in an actor:
/// ```
/// actor MyCache: PeriodicCleanupHandler {
///     private let cleanupTask = PeriodicCleanupTask()
///
///     private init() {
///         Task { await cleanupTask.start(handler: self, interval: .hours(1)) }
///     }
///
///     func performCleanup() async {
///         // Cleanup logic
///     }
/// }
/// ```
final class PeriodicCleanupTask: @unchecked Sendable {
    private var task: Task<Void, Never>?
    private weak var handler: (any PeriodicCleanupHandler)?

    /// Common cleanup intervals
    enum Interval {
        case minutes(_ minutes: Int)
        case hours(_ hours: Int)

        var nanoseconds: UInt64 {
            switch self {
            case .minutes(let m):
                return UInt64(m) * 60 * 1_000_000_000
            case .hours(let h):
                return UInt64(h) * 60 * 60 * 1_000_000_000
            }
        }
    }

    init() {}

    /// Starts the periodic cleanup task
    /// - Parameters:
    ///   - handler: The handler that performs cleanup
    ///   - interval: The interval between cleanup operations
    ///   - runImmediately: Whether to run cleanup immediately before starting the periodic loop
    func start(
        handler: any PeriodicCleanupHandler,
        interval: Interval,
        runImmediately: Bool = true
    ) {
        self.handler = handler

        task = Task { [weak self] in
            // Optional initial cleanup
            if runImmediately {
                await handler.performCleanup()
            }

            // Periodic cleanup loop
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: interval.nanoseconds)
                    await self?.handler?.performCleanup()
                } catch {
                    // Task was cancelled
                    break
                }
            }
        }
    }

    /// Cancels the periodic cleanup task
    func cancel() {
        task?.cancel()
        task = nil
        handler = nil
    }

    deinit {
        cancel()
    }
}
