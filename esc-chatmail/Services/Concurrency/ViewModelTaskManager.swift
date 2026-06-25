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
    private struct ManagedTask {
        let id: UUID
        let task: Task<Void, Never>
    }

    private var tasks: [String: ManagedTask] = [:]

#if DEBUG
    var taskCleanupAttemptObserver: ((String) -> Void)?
#endif

    /// Runs an async operation, cancelling any existing task with the same key.
    ///
    /// - Parameters:
    ///   - key: Unique identifier for this task type
    ///   - priority: Task priority (default: nil, inherits from current context)
    ///   - operation: The async operation to perform
    func run(_ key: String, priority: TaskPriority? = nil, operation: @escaping () async -> Void) {
        tasks[key]?.task.cancel()

        let taskID = UUID()
        let task = Task(priority: priority) { [weak self] in
            await operation()
            await MainActor.run {
                self?.clearTaskIfCurrent(key: key, id: taskID)
            }
        }
        tasks[key] = ManagedTask(id: taskID, task: task)
    }

    /// Runs a detached async operation, cancelling any existing task with the same key.
    ///
    /// Use this for operations that should run without inheriting the current actor context.
    ///
    /// - Parameters:
    ///   - key: Unique identifier for this task type
    ///   - operation: The async operation to perform
    func runDetached(_ key: String, operation: @Sendable @escaping () async -> Void) {
        tasks[key]?.task.cancel()

        let taskID = UUID()
        weak let weakSelf = self
        let task = Task.detached {
            await operation()
            await MainActor.run {
                weakSelf?.clearTaskIfCurrent(key: key, id: taskID)
            }
        }
        tasks[key] = ManagedTask(id: taskID, task: task)
    }

    /// Cancels the task with the specified key.
    ///
    /// - Parameter key: The task key to cancel
    func cancel(_ key: String) {
        tasks[key]?.task.cancel()
        tasks[key] = nil
    }

    /// Cancels all managed tasks.
    ///
    /// Call this in view/ViewModel cleanup (e.g., onDisappear, deinit).
    func cancelAll() {
        for managedTask in tasks.values {
            managedTask.task.cancel()
        }
        tasks.removeAll()
    }

    private func clearTaskIfCurrent(key: String, id: UUID) {
#if DEBUG
        taskCleanupAttemptObserver?(key)
#endif

        guard tasks[key]?.id == id else {
            return
        }

        tasks.removeValue(forKey: key)
    }
}
