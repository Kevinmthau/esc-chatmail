import Foundation

enum BackgroundMailboxSyncBudget: Equatable, Sendable {
    case appRefresh
    case processing

    var historyPageLimit: Int {
        switch self {
        case .appRefresh:
            return SyncConfig.maxHistoryPagesPerAppRefreshSlice
        case .processing:
            return SyncConfig.maxHistoryPagesPerProcessingSlice
        }
    }

    var historyPageSize: Int {
        switch self {
        case .appRefresh:
            return SyncConfig.maxHistoryResultsPerAppRefreshRequest
        case .processing:
            return SyncConfig.maxHistoryResultsPerProcessingRequest
        }
    }

    var allowsExpensiveRecovery: Bool {
        self == .processing
    }

    /// Whether the 6-hour store-wide maintenance may follow this task's
    /// sync. An app refresh has about half a minute, and the passes read
    /// every active conversation: they wait for a processing task or for
    /// the next foreground sync.
    var allowsStoreMaintenance: Bool {
        self == .processing
    }
}
