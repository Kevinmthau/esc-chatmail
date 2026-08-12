import Foundation
import BackgroundTasks

/// Handles background task registration and scheduling
final class BackgroundTaskScheduler {
    static let shared = BackgroundTaskScheduler()

    typealias PendingTaskRequestsProvider = (@escaping ([BGTaskRequest]) -> Void) -> Void

    private let refreshTaskIdentifier = "com.esc.inboxchat.refresh"
    private let processingTaskIdentifier = "com.esc.inboxchat.processing"
    private let pendingTaskRequestsProvider: PendingTaskRequestsProvider

    /// Callback for app refresh tasks
    var onAppRefresh: ((BGAppRefreshTask) -> Void)?
    /// Callback for processing tasks
    var onProcessing: ((BGProcessingTask) -> Void)?

    private convenience init() {
        self.init { completion in
            BGTaskScheduler.shared.getPendingTaskRequests(completionHandler: completion)
        }
    }

    init(pendingTaskRequestsProvider: @escaping PendingTaskRequestsProvider) {
        self.pendingTaskRequestsProvider = pendingTaskRequestsProvider
    }

    /// Registers background tasks with the system
    func registerBackgroundTasks() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: refreshTaskIdentifier, using: nil) { [weak self] task in
            guard let task = task as? BGAppRefreshTask else { return }
            self?.onAppRefresh?(task)
        }

        BGTaskScheduler.shared.register(forTaskWithIdentifier: processingTaskIdentifier, using: nil) { [weak self] task in
            guard let task = task as? BGProcessingTask else { return }
            self?.onProcessing?(task)
        }
    }

    /// Schedules an app refresh task (15 minute interval)
    func scheduleAppRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: refreshTaskIdentifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)

        do {
            try BGTaskScheduler.shared.submit(request)
            Log.debug("Background refresh scheduled", category: .background)
        } catch {
            Log.error("Failed to schedule background refresh", category: .background, error: error)
        }
    }

    /// Schedules a processing task (60 minute interval)
    func scheduleProcessingTask() {
        let request = BGProcessingTaskRequest(identifier: processingTaskIdentifier)
        request.requiresNetworkConnectivity = true
        request.requiresExternalPower = false
        request.earliestBeginDate = Date(timeIntervalSinceNow: 60 * 60)

        do {
            try BGTaskScheduler.shared.submit(request)
            Log.debug("Background processing scheduled", category: .background)
        } catch {
            Log.error("Failed to schedule background processing", category: .background, error: error)
        }
    }

    /// Whether a processing-task request is already waiting with the system.
    /// Submitting the same identifier again would REPLACE the pending request
    /// and push its `earliestBeginDate` another hour out, so escalation paths
    /// must check this before re-submitting.
    func isProcessingTaskPending() async -> Bool {
        await isTaskPending(identifier: processingTaskIdentifier)
    }

    /// Cancels the pending refresh and processing requests. Sign-out relies on
    /// this to disarm background wakes: both task handlers re-arm at entry
    /// before `performAuthoritativeSync`'s unauthenticated guard runs, so a
    /// request that survives sign-out wakes the signed-out device on the sync
    /// cadence indefinitely. The database-maintenance identifiers are
    /// deliberately not cancelled — they are store-scoped, not account-scoped,
    /// and `initializeApp` re-arms any that are not still pending at every
    /// launch.
    func cancelPendingTaskRequests() {
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: refreshTaskIdentifier)
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: processingTaskIdentifier)
        Log.debug("Cancelled pending background sync task requests", category: .background)
    }

    /// Whether an app-refresh request is already waiting with the system.
    /// Same REPLACE semantics as the processing identifier. Every submit path
    /// for this identifier uses a delay of at most 15 minutes, so a pending
    /// request always begins no later than a fresh re-submit would — ordinary
    /// cadence re-arms should skip rather than replace, preserving the
    /// sooner-dated backoff/catch-up retries that share the identifier.
    func isAppRefreshTaskPending() async -> Bool {
        await isTaskPending(identifier: refreshTaskIdentifier)
    }

    /// Bridges `BGTaskScheduler`'s callback without trapping a cancelled
    /// background worker if the system never invokes that callback. Returning
    /// `true` on cancellation is conservative: every caller interprets it as
    /// "leave the existing request alone" and therefore submits nothing.
    private func isTaskPending(identifier: String) async -> Bool {
        let resultGate = SingleFireContinuationGate<Bool>()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if let settledResult = resultGate.install(continuation) {
                    continuation.resume(returning: settledResult)
                    return
                }

                pendingTaskRequestsProvider { requests in
                    resultGate.resume(
                        returning: requests.contains { $0.identifier == identifier }
                    )
                }
            }
        } onCancel: {
            resultGate.resume(returning: true)
        }
    }

    /// Schedules a retry after the specified backoff interval
    func scheduleRetryAfterBackoff(_ backoff: TimeInterval) {
        let request = BGAppRefreshTaskRequest(identifier: refreshTaskIdentifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: backoff)

        do {
            try BGTaskScheduler.shared.submit(request)
            Log.debug("Retry scheduled after \(backoff) seconds", category: .background)
        } catch {
            Log.error("Failed to schedule retry", category: .background, error: error)
        }
    }
}
