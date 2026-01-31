import Foundation

/// A utility for managing async tasks in ViewModels.
///
/// Handles the common pattern of cancelling previous tasks before starting new ones,
/// preventing orphaned tasks during rapid state changes.
///
/// Usage:
/// ```swift
/// @MainActor
/// final class MyViewModel: ObservableObject {
///     private let taskManager = ViewModelTaskManager()
///
///     func load() {
///         taskManager.run("load") { [weak self] in
///             await self?.performLoad()
///         }
///     }
///
///     func cleanup() {
///         taskManager.cancelAll()
///     }
/// }
/// ```
@MainActor
final class ViewModelTaskManager {
    private var tasks: [String: Task<Void, Never>] = [:]

    /// Runs an async operation, cancelling any existing task with the same key.
    ///
    /// - Parameters:
    ///   - key: Unique identifier for this task type
    ///   - priority: Task priority (default: nil, inherits from current context)
    ///   - operation: The async operation to perform
    func run(_ key: String, priority: TaskPriority? = nil, operation: @escaping () async -> Void) {
        tasks[key]?.cancel()
        tasks[key] = Task(priority: priority) {
            await operation()
        }
    }

    /// Runs a detached async operation, cancelling any existing task with the same key.
    ///
    /// Use this for operations that should run without inheriting the current actor context.
    ///
    /// - Parameters:
    ///   - key: Unique identifier for this task type
    ///   - operation: The async operation to perform
    func runDetached(_ key: String, operation: @Sendable @escaping () async -> Void) {
        tasks[key]?.cancel()
        tasks[key] = Task.detached {
            await operation()
        }
    }

    /// Cancels the task with the specified key.
    ///
    /// - Parameter key: The task key to cancel
    func cancel(_ key: String) {
        tasks[key]?.cancel()
        tasks[key] = nil
    }

    /// Cancels all managed tasks.
    ///
    /// Call this in view/ViewModel cleanup (e.g., onDisappear, deinit).
    func cancelAll() {
        for task in tasks.values {
            task.cancel()
        }
        tasks.removeAll()
    }

    /// Returns true if a task with the given key exists and hasn't been cancelled.
    ///
    /// - Note: This only checks if the task was cancelled, not if it completed.
    ///         Swift's Task API doesn't provide a way to check completion state.
    ///         For reliable completion tracking, use the task's result or a separate flag.
    ///
    /// - Parameter key: The task key to check
    /// - Returns: Whether the task exists and hasn't been cancelled
    func hasActiveTask(_ key: String) -> Bool {
        guard let task = tasks[key] else { return false }
        return !task.isCancelled
    }
}
