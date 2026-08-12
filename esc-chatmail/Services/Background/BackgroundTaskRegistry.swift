import Foundation
import BackgroundTasks

/// Centralized registry for managing background tasks
/// Eliminates repetitive register/schedule/handle code patterns
final class BackgroundTaskRegistry {
    static let shared = BackgroundTaskRegistry()

    /// Stored task handlers and configurations
    private var taskHandlers: [String: () async -> Bool] = [:]
    private var taskConfigurations: [String: BackgroundTaskConfiguration] = [:]

    /// `BGTaskScheduler` seams. Injectable because the real scheduler cannot
    /// back hosted unit tests: the app already registered every identifier at
    /// launch, re-registering one is a process-aborting assertion, and the
    /// simulator rejects submits outright.
    private let registerLaunchHandler: @Sendable (String, @escaping (BGTask) -> Void) -> Void
    private let submitTaskRequest: @Sendable (BGTaskRequest) throws -> Void
    private let pendingTaskIdentifiers: @Sendable () async -> Set<String>

    /// Internal (not private) only so tests can construct an instance with
    /// spy seams. Never build a second instance around the default real
    /// `BGTaskScheduler` closures: re-registering an identifier it already
    /// holds is an Apple assertion failure that aborts the process.
    ///
    /// The handler/configuration dictionaries are deliberately unsynchronized:
    /// every `register` call happens on the main thread during app launch,
    /// before any scheduling read or `BGTaskScheduler`-queue launch-handler
    /// callback can race them. A registrant added from another executor after
    /// launch would be a Dictionary data race — don't add one.
    init(
        registerLaunchHandler: @escaping @Sendable (String, @escaping (BGTask) -> Void) -> Void = { identifier, launchHandler in
            _ = BGTaskScheduler.shared.register(
                forTaskWithIdentifier: identifier,
                using: nil,
                launchHandler: launchHandler
            )
        },
        submitTaskRequest: @escaping @Sendable (BGTaskRequest) throws -> Void = { request in
            try BGTaskScheduler.shared.submit(request)
        },
        pendingTaskIdentifiers: @escaping @Sendable () async -> Set<String> = {
            await withCheckedContinuation { continuation in
                BGTaskScheduler.shared.getPendingTaskRequests { requests in
                    continuation.resume(returning: Set(requests.map(\.identifier)))
                }
            }
        }
    ) {
        self.registerLaunchHandler = registerLaunchHandler
        self.submitTaskRequest = submitTaskRequest
        self.pendingTaskIdentifiers = pendingTaskIdentifiers
    }

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
            registerLaunchHandler(config.identifier) { [weak self] task in
                guard let appRefreshTask = task as? BGAppRefreshTask else {
                    Log.error("Unexpected task type for appRefresh: \(type(of: task))", category: .background)
                    task.setTaskCompleted(success: false)
                    return
                }
                self?.handleTask(appRefreshTask, identifier: config.identifier)
            }

        case .processing:
            registerLaunchHandler(config.identifier) { [weak self] task in
                guard let processingTask = task as? BGProcessingTask else {
                    Log.error("Unexpected task type for processing: \(type(of: task))", category: .background)
                    task.setTaskCompleted(success: false)
                    return
                }
                self?.handleTask(processingTask, identifier: config.identifier)
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
            try submitTaskRequest(request)
            Log.debug("Scheduled background task: \(identifier)", category: .background)
        } catch {
            Log.error("Failed to schedule task: \(identifier)", category: .background, error: error)
        }
    }

    /// Schedules each identifier whose request is not already waiting with the
    /// system, using a single pending-request fetch for the whole batch.
    ///
    /// A `BGTaskScheduler` submit with an already-pending identifier REPLACES
    /// the pending request and pushes its `earliestBeginDate` out by the full
    /// configured interval, so launch-path re-scheduling must skip pending
    /// identifiers — an unconditional re-submit on every cold launch keeps a
    /// daily task perpetually ineligible for any user who launches more often
    /// than the interval. The post-fire re-arm in `handleTask` deliberately
    /// stays a plain `schedule(_:)`: the fired request was just consumed, so
    /// nothing is pending and the guard would only add a needless fetch.
    ///
    /// Trade-off accepted (same as the #166 processing-task guard): a skipped
    /// identifier keeps the configuration it was submitted with, so a changed
    /// interval or power/network flag reaches the system only after the
    /// pending request fires or is cancelled — up to one full interval late.
    func scheduleIfNotPending(_ identifiers: [String]) async {
        guard !identifiers.isEmpty else { return }

        let pending = await pendingTaskIdentifiers()

        for identifier in identifiers {
            if pending.contains(identifier) {
                Log.debug("Skipping still-pending background task: \(identifier)", category: .background)
            } else {
                schedule(identifier)
            }
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
