import Foundation
import BackgroundTasks

/// Abstraction over `BackgroundTaskScheduler`'s surface so background-sync
/// orchestration can be exercised with a spy instead of the real
/// `BGTaskScheduler` (which cannot run under unit tests).
protocol BackgroundTaskScheduling: AnyObject {
    var onAppRefresh: ((BGAppRefreshTask) -> Void)? { get set }
    var onProcessing: ((BGProcessingTask) -> Void)? { get set }
    func registerBackgroundTasks()
    /// Submits the app-refresh request (15-minute delay). A submit with an
    /// already-pending identifier REPLACES the pending request — including a
    /// sooner-dated backoff/catch-up retry from `scheduleRetryAfterBackoff(_:)`,
    /// which shares the identifier. Outside a fired handler's immediate re-arm,
    /// consult `isAppRefreshTaskPending()` first.
    func scheduleAppRefresh()
    /// Submits the processing request (60-minute delay). A submit with an
    /// already-pending identifier REPLACES the pending request and pushes its
    /// `earliestBeginDate` another hour out — unguarded periodic callers
    /// postpone the task indefinitely. The only caller that may submit
    /// unguarded is a fired processing handler's immediate re-arm (the
    /// delivered request was just consumed); every other caller goes through
    /// `BackgroundSyncManager.scheduleProcessingTaskIfNotPending()` or
    /// consults `isProcessingTaskPending()` first.
    func scheduleProcessingTask()
    func isProcessingTaskPending() async -> Bool
    func isAppRefreshTaskPending() async -> Bool
    func scheduleRetryAfterBackoff(_ backoff: TimeInterval)
}

extension BackgroundTaskScheduler: BackgroundTaskScheduling {}
