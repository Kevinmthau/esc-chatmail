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
}
