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
        tasks[key] = Task(priority: priority) { [weak self] in
            await operation()
            _ = await MainActor.run {
                self?.tasks.removeValue(forKey: key)
            }
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
        weak let weakSelf = self
        tasks[key] = Task.detached {
            await operation()
            _ = await MainActor.run {
                weakSelf?.tasks.removeValue(forKey: key)
            }
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
}
