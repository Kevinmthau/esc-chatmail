import Foundation

/// The slice of `PendingActionsManager` the conversation list's
/// abandoned-action banner needs, so its model can be tested without the
/// whole queue.
protocol AbandonedPendingActionsManaging: Sendable {
    func fetchAbandonedActions() async -> [AbandonedActionInfo]
    func retryAllAbandonedActions() async
    func dismissAllAbandonedActions() async
}

extension PendingActionsManager: AbandonedPendingActionsManaging {}
