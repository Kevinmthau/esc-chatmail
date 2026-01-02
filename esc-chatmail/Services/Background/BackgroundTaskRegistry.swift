import Foundation
import BackgroundTasks

/// Centralized registry for managing background tasks
/// Eliminates repetitive register/schedule/handle code patterns
final class BackgroundTaskRegistry {
    static let shared = BackgroundTaskRegistry()

    /// Stored task handlers and configurations
    private var taskHandlers: [String: () async -> Bool] = [:]
    private var taskConfigurations: [String: BackgroundTaskConfiguration] = [:]

    private init() {}

    // MARK: - Registration

    /// Registers a background task with its configuration and handler
    /// - Parameters:
    ///   - config: The task configuration
    ///   - handler: Async handler that returns success/failure
    func register(
        config: BackgroundTaskConfiguration,
        handler: @escaping () async -> Bool
    ) {
        taskConfigurations[config.identifier] = config
        taskHandlers[config.identifier] = handler

        switch config.taskType {
        case .appRefresh:
            BGTaskScheduler.shared.register(
                forTaskWithIdentifier: config.identifier,
                using: nil
            ) { [weak self] task in
                self?.handleTask(task as! BGAppRefreshTask, identifier: config.identifier)
            }

        case .processing:
            BGTaskScheduler.shared.register(
                forTaskWithIdentifier: config.identifier,
                using: nil
            ) { [weak self] task in
                self?.handleTask(task as! BGProcessingTask, identifier: config.identifier)
            }
        }

        Log.debug("Registered background task: \(config.identifier)", category: .background)
    }

    // MARK: - Scheduling

    /// Schedules a previously registered task
    /// - Parameter identifier: The task identifier
    func schedule(_ identifier: String) {
        guard let config = taskConfigurations[identifier] else {
            Log.warning("Cannot schedule unknown task: \(identifier)", category: .background)
            return
        }

        let request: BGTaskRequest

        switch config.taskType {
        case .appRefresh:
            let appRefreshRequest = BGAppRefreshTaskRequest(identifier: identifier)
            appRefreshRequest.earliestBeginDate = Date(timeIntervalSinceNow: config.interval)
            request = appRefreshRequest

        case .processing:
            let processingRequest = BGProcessingTaskRequest(identifier: identifier)
            processingRequest.earliestBeginDate = Date(timeIntervalSinceNow: config.interval)
            processingRequest.requiresNetworkConnectivity = config.requiresNetworkConnectivity
            processingRequest.requiresExternalPower = config.requiresExternalPower
            request = processingRequest
        }

        do {
            try BGTaskScheduler.shared.submit(request)
            Log.debug("Scheduled background task: \(identifier)", category: .background)
        } catch {
            Log.error("Failed to schedule task: \(identifier)", category: .background, error: error)
        }
    }

    /// Schedules all registered tasks
    func scheduleAll() {
        for identifier in taskConfigurations.keys {
            schedule(identifier)
        }
    }

    // MARK: - Private Handling

    private func handleTask(_ task: BGTask, identifier: String) {
        guard let handler = taskHandlers[identifier] else {
            Log.warning("No handler for task: \(identifier)", category: .background)
            task.setTaskCompleted(success: false)
            return
        }

        // Set expiration handler
        task.expirationHandler = {
            task.setTaskCompleted(success: false)
        }

        // Execute the handler
        Task {
            let success = await handler()
            task.setTaskCompleted(success: success)

            // Reschedule for next time
            self.schedule(identifier)
        }
    }

    // MARK: - Utilities

    /// Cancels a specific pending task
    func cancel(_ identifier: String) {
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: identifier)
        Log.debug("Cancelled background task: \(identifier)", category: .background)
    }

    /// Cancels all pending tasks
    func cancelAll() {
        BGTaskScheduler.shared.cancelAllTaskRequests()
        Log.debug("Cancelled all background tasks", category: .background)
    }

    /// Returns all registered task identifiers
    var registeredIdentifiers: [String] {
        Array(taskConfigurations.keys)
    }
}
