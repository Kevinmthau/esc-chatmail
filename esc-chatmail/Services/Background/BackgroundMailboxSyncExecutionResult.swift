import Foundation

enum BackgroundMailboxSyncExecutionResult: Equatable, Sendable {
    case completed
    case needsFollowUp
    case blocked(by: SyncRunKind?)
    case failed
    /// Refused or stopped because the disk is full. Not a retryable failure: the short failure
    /// backoff would only start another run against the same full disk.
    case deferredForInsufficientStorage
}
