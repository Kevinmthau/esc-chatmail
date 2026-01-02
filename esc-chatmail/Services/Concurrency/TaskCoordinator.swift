import Foundation

/// A generic actor that prevents duplicate concurrent operations.
/// Ensures only one task runs at a time for a given operation type.
///
/// Usage:
/// ```swift
/// let coordinator = TaskCoordinator<String>()
/// let result = try await coordinator.getOrCreate {
///     Task { try await someExpensiveOperation() }
/// }
/// ```
public actor TaskCoordinator<T: Sendable> {
    private var currentTask: Task<T, Error>?

    public init() {}

    /// Returns an existing in-flight task or creates a new one using the factory.
    /// This ensures only one task runs at a time.
    /// - Parameter factory: A closure that creates a new task if none exists
    /// - Returns: The existing or newly created task
    public func getOrCreateTask(_ factory: () -> Task<T, Error>) -> Task<T, Error> {
        if let existing = currentTask {
            return existing
        }
        let newTask = factory()
        currentTask = newTask
        return newTask
    }

    /// Clears the current task reference.
    /// Call this when the task completes (typically in a defer block).
    public func clearTask() {
        currentTask = nil
    }

    /// Returns whether there's currently an in-flight task.
    public var hasInFlightTask: Bool {
        currentTask != nil
    }
}

/// A variant that supports non-throwing tasks.
public actor TaskCoordinatorNonThrowing<T: Sendable> {
    private var currentTask: Task<T, Never>?

    public init() {}

    /// Returns an existing in-flight task or creates a new one using the factory.
    public func getOrCreateTask(_ factory: () -> Task<T, Never>) -> Task<T, Never> {
        if let existing = currentTask {
            return existing
        }
        let newTask = factory()
        currentTask = newTask
        return newTask
    }

    /// Clears the current task reference.
    public func clearTask() {
        currentTask = nil
    }

    /// Returns whether there's currently an in-flight task.
    public var hasInFlightTask: Bool {
        currentTask != nil
    }
}
