import Foundation
import BackgroundTasks

/// Abstraction over `BackgroundTaskScheduler`'s surface so background-sync
/// orchestration can be exercised with a spy instead of the real
/// `BGTaskScheduler` (which cannot run under unit tests).
protocol BackgroundTaskScheduling: AnyObject {
    var onAppRefresh: ((BGAppRefreshTask) -> Void)? { get set }
    var onProcessing: ((BGProcessingTask) -> Void)? { get set }
    func registerBackgroundTasks()
    func scheduleAppRefresh()
    func scheduleProcessingTask()
    func isProcessingTaskPending() async -> Bool
    func scheduleRetryAfterBackoff(_ backoff: TimeInterval)
}

extension BackgroundTaskScheduler: BackgroundTaskScheduling {}
