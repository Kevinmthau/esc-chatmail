import Foundation
import BackgroundTasks

/// Handles background task registration and scheduling
final class BackgroundTaskScheduler {
    static let shared = BackgroundTaskScheduler()

    private let refreshTaskIdentifier = "com.esc.inboxchat.refresh"
    private let processingTaskIdentifier = "com.esc.inboxchat.processing"

    /// Callback for app refresh tasks
    var onAppRefresh: ((BGAppRefreshTask) -> Void)?
    /// Callback for processing tasks
    var onProcessing: ((BGProcessingTask) -> Void)?

    private init() {}

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
        await withCheckedContinuation { continuation in
            BGTaskScheduler.shared.getPendingTaskRequests { [processingTaskIdentifier] requests in
                continuation.resume(
                    returning: requests.contains { $0.identifier == processingTaskIdentifier }
                )
            }
        }
    }

    /// Cancels the pending refresh and processing requests. Sign-out relies on
    /// this to disarm background wakes: both task handlers re-arm at entry
    /// before `performAuthoritativeSync`'s unauthenticated guard runs, so a
    /// request that survives sign-out wakes the signed-out device on the sync
    /// cadence indefinitely. The database-maintenance identifiers are
    /// deliberately not cancelled — they are store-scoped, not account-scoped,
    /// and `initializeApp` re-arms them unconditionally at every launch.
    func cancelPendingTaskRequests() {
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: refreshTaskIdentifier)
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: processingTaskIdentifier)
        Log.debug("Cancelled pending background sync task requests", category: .background)
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
