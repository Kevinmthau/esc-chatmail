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

    /// Convenience method that executes an operation with automatic task cleanup.
    /// Returns the existing in-flight task's result if one exists, otherwise creates and runs a new task.
    /// The task reference is automatically cleared when the operation completes.
    /// - Parameter operation: The async operation to execute
    /// - Returns: The result of the operation
    public func execute(_ operation: @escaping @Sendable () async throws -> T) async throws -> T {
        if let existing = currentTask {
            return try await existing.value
        }
        let task = Task<T, Error> { try await operation() }
        currentTask = task
        defer { currentTask = nil }
        return try await task.value
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

    /// Convenience method that executes an operation with automatic task cleanup.
    /// Returns the existing in-flight task's result if one exists, otherwise creates and runs a new task.
    /// The task reference is automatically cleared when the operation completes.
    /// - Parameter operation: The async operation to execute
    /// - Returns: The result of the operation
    public func execute(_ operation: @escaping @Sendable () async -> T) async -> T {
        if let existing = currentTask {
            return await existing.value
        }
        let task = Task<T, Never> { await operation() }
        currentTask = task
        defer { currentTask = nil }
        return await task.value
    }
}
