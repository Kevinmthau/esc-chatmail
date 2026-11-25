#if os(iOS)
import Foundation
import BackgroundTasks

/// The iOS maintenance scheduler. On the Mac, where every `BG*` type is
/// unavailable, `BackgroundActivityTaskRegistry` takes its place.
typealias PlatformBackgroundTaskRegistry = BackgroundTaskRegistry

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
    private let cancelPendingTaskRequest: @Sendable (String) -> Void
    /// Where each run's outcome is recorded (`BackgroundRunJournal`).
    private let runJournal: BackgroundRunJournal
    private let now: @Sendable () -> Date

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
        },
        cancelPendingTaskRequest: @escaping @Sendable (String) -> Void = { identifier in
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: identifier)
        },
        runJournal: BackgroundRunJournal = .shared,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.registerLaunchHandler = registerLaunchHandler
        self.submitTaskRequest = submitTaskRequest
        self.pendingTaskIdentifiers = pendingTaskIdentifiers
        self.cancelPendingTaskRequest = cancelPendingTaskRequest
        self.runJournal = runJournal
        self.now = now
    }

    /// A maintenance task's name in `BackgroundRunJournal`: its identifier without the
    /// bundle prefix (`database.analyze`).
    static func journalName(for identifier: String) -> String {
        let prefix = "com.esc.inboxchat."
        return identifier.hasPrefix(prefix) ? String(identifier.dropFirst(prefix.count)) : identifier
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

    /// Keeps a launch handler for an identifier the app no longer schedules,
    /// and cancels the request an earlier build may have left with the
    /// system. The handler completes the task at once. It has to exist:
    /// `BGTaskScheduler` raises when it launches the app for an identifier
    /// nothing registered. The identifier gets no configuration, so
    /// `schedule(_:)` cannot submit it again.
    func retire(_ identifier: String) {
        registerLaunchHandler(identifier) { task in
            task.setTaskCompleted(success: true)
        }
        cancelPendingTaskRequest(identifier)
        Log.debug("Retired background task: \(identifier)", category: .background)
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

        runTaskOperation(
            identifier: identifier,
            handler: handler,
            installExpirationHandler: { expirationHandler in
                task.expirationHandler = expirationHandler
            },
            onComplete: { success in
                task.setTaskCompleted(success: success)
            }
        )
    }

    /// Runs a fired task's handler and completes the task exactly once, after
    /// the handler has returned.
    ///
    /// Expiration cancels the handler's task and forces the result to
    /// failure; it does not complete the task itself. It did: it called
    /// `setTaskCompleted(false)` and left the handler running, uncancelled,
    /// to complete the task a second time when it ended. A maintenance
    /// handler holds the exclusive store run, so an expired one went on
    /// holding it, across the suspension, until the app was next opened.
    /// Completing only once the cancelled handler has unwound is also what
    /// lets it release that run first: iOS may suspend the process as soon
    /// as `setTaskCompleted` returns.
    ///
    /// The next request is submitted before the completion, for the same
    /// reason.
    ///
    /// Closure-based, as `BackgroundSyncManager.runBackgroundTaskOperation`
    /// is, because `BGTask` has no public initializer for a test to use.
    func runTaskOperation(
        identifier: String,
        handler: @escaping () async -> Bool,
        installExpirationHandler: (@escaping () -> Void) -> Void,
        onComplete: @escaping (Bool) -> Void
    ) {
        let completionLatch = BackgroundTaskCompletionLatch(onComplete: onComplete)
        let cancellationLatch = BackgroundTaskCancellationLatch()
        let startedAt = now()
        let journal = runJournal
        let now = self.now

        // Installed before the worker exists. The cancellation latch
        // remembers an expiration that arrives first.
        installExpirationHandler {
            completionLatch.expire()
            cancellationLatch.expire()
        }

        let worker = Task {
            await handler()
        }
        cancellationLatch.install {
            worker.cancel()
        }

        Task {
            let success = await worker.value
            // Reschedule for next time
            self.schedule(identifier)
            completionLatch.complete(success: success) { reported, didExpire in
                // Before `setTaskCompleted`, after which iOS may suspend the process.
                journal.record(
                    task: Self.journalName(for: identifier),
                    startedAt: startedAt,
                    endedAt: now(),
                    outcome: success ? .maintenanceSucceeded : .maintenanceFailed,
                    reported: reported,
                    expired: didExpire
                )
            }
        }
    }

    // MARK: - Utilities

    /// Cancels a specific pending task
    func cancel(_ identifier: String) {
        cancelPendingTaskRequest(identifier)
        Log.debug("Cancelled background task: \(identifier)", category: .background)
    }

    /// Returns all registered task identifiers
    var registeredIdentifiers: [String] {
        Array(taskConfigurations.keys)
    }
}

/// Declared in an extension, not on the class: a conformance on the primary
/// declaration would infer `@MainActor` for the whole class from the
/// protocol, and `handleTask` runs on `BGTaskScheduler`'s launch-handler queue.
extension BackgroundTaskRegistry: BackgroundTaskRegistering {}
#endif
