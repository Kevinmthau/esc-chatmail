import Foundation

/// The model-v3 mailbox sync entry point used by `BGTask` launches. The
/// production implementation owns and cancels the exact incremental run it
/// starts, while tests can exercise the background hand-off without creating
/// `BGTask` instances (which Apple does not expose public initializers for).
///
/// Compiled on both platforms although only iOS's `BackgroundSyncManager`
/// calls it: `SyncEngine` conforms, and the Mac has no BGTask launches.
@MainActor
protocol BackgroundMailboxSyncExecuting: AnyObject, Sendable {
    func performIncrementalSyncForBackground(
        budget: BackgroundMailboxSyncBudget
    ) async -> BackgroundMailboxSyncExecutionResult
}

extension SyncEngine: BackgroundMailboxSyncExecuting {}
