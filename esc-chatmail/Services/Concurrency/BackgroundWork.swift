import Foundation

/// Utility for coordinating background work off the main actor.
///
/// Use `BackgroundWork` to execute CPU-intensive operations without blocking
/// the main thread. This provides a cleaner API than raw `Task.detached`.
///
/// Usage:
/// ```swift
/// // Execute and await result
/// let image = await BackgroundWork.execute {
///     UIImage(data: imageData)
/// }
///
/// // Fire-and-forget
/// BackgroundWork.spawn {
///     await heavyProcessing()
/// }
/// ```
enum BackgroundWork {

    /// Executes a non-throwing operation in a detached task and returns the result.
    ///
    /// Use this for CPU-intensive work that should not block the main actor.
    /// The work is executed with the specified priority (default: `.userInitiated`).
    ///
    /// - Parameters:
    ///   - priority: The task priority for execution
    ///   - work: The work to execute
    /// - Returns: The result of the work
    static func execute<T: Sendable>(
        priority: TaskPriority = .userInitiated,
        _ work: @escaping @Sendable () -> T
    ) async -> T {
        await Task.detached(priority: priority, operation: work).value
    }

    /// Executes a throwing operation in a detached task and returns the result.
    ///
    /// Use this for CPU-intensive work that may throw errors.
    ///
    /// - Parameters:
    ///   - priority: The task priority for execution
    ///   - work: The work to execute
    /// - Returns: The result of the work
    /// - Throws: Any error thrown by the work
    static func execute<T: Sendable>(
        priority: TaskPriority = .userInitiated,
        _ work: @escaping @Sendable () throws -> T
    ) async throws -> T {
        try await Task.detached(priority: priority, operation: work).value
    }

    /// Executes an async operation in a detached task and returns the result.
    ///
    /// Use this when the background work itself needs to perform async operations.
    ///
    /// - Parameters:
    ///   - priority: The task priority for execution
    ///   - work: The async work to execute
    /// - Returns: The result of the work
    static func executeAsync<T: Sendable>(
        priority: TaskPriority = .userInitiated,
        _ work: @escaping @Sendable () async -> T
    ) async -> T {
        await Task.detached(priority: priority, operation: work).value
    }

    /// Executes a throwing async operation in a detached task and returns the result.
    ///
    /// - Parameters:
    ///   - priority: The task priority for execution
    ///   - work: The async work to execute
    /// - Returns: The result of the work
    /// - Throws: Any error thrown by the work
    static func executeAsync<T: Sendable>(
        priority: TaskPriority = .userInitiated,
        _ work: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await Task.detached(priority: priority, operation: work).value
    }

    /// Spawns fire-and-forget background work.
    ///
    /// Use this when you don't need to await the result. The work will execute
    /// independently and any errors will be ignored.
    ///
    /// - Parameters:
    ///   - priority: The task priority for execution (default: `.utility`)
    ///   - work: The async work to execute
    @discardableResult
    static func spawn(
        priority: TaskPriority = .utility,
        _ work: @escaping @Sendable () async -> Void
    ) -> Task<Void, Never> {
        Task.detached(priority: priority) {
            await work()
        }
    }

    /// Spawns fire-and-forget background work with error logging.
    ///
    /// Similar to `spawn`, but logs any errors that occur during execution.
    ///
    /// - Parameters:
    ///   - priority: The task priority for execution
    ///   - category: The log category for error logging
    ///   - work: The async work to execute
    @discardableResult
    static func spawnWithLogging(
        priority: TaskPriority = .utility,
        category: LogCategory = .background,
        _ work: @escaping @Sendable () async throws -> Void
    ) -> Task<Void, Never> {
        Task.detached(priority: priority) {
            do {
                try await work()
            } catch {
                Log.error("Background work failed", category: category, error: error)
            }
        }
    }
}
