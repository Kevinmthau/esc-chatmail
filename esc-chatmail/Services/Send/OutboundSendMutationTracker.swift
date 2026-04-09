import Foundation

extension Notification.Name {
    static let outboundSendMutationChanged = Notification.Name("com.esc.inboxchat.outboundSendMutationChanged")
    static let outboundSendFailed = Notification.Name("com.esc.inboxchat.outboundSendFailed")
}

@MainActor
protocol OutboundSendMutationTracking: AnyObject {
    func trackPendingMutation(_ mutation: OutboundSendMutationTracker.PendingMutation)
    func reconcileSuccess(_ success: OutboundMessageReconciliationHooks.Success)
    func reconcileFailure(_ failure: OutboundMessageReconciliationHooks.Failure)
    var pendingMutationCount: Int { get }
    var failedMutations: [OutboundSendMutationTracker.FailedMutation] { get }
}

/// Tracks outbound mailbox mutations created by optimistic sends until Gmail
/// send success or failure reconciles them.
@MainActor
final class OutboundSendMutationTracker: OutboundSendMutationTracking {
    struct PendingMutation: Identifiable, Sendable {
        let id: String
        let conversationObjectURI: String?
        let createdAt: Date

        init(
            optimisticMessageID: String,
            conversationObjectURI: String?,
            createdAt: Date = Date()
        ) {
            self.id = optimisticMessageID
            self.conversationObjectURI = conversationObjectURI
            self.createdAt = createdAt
        }
    }

    struct FailedMutation: Identifiable, Sendable {
        let id: String
        let conversationObjectURI: String?
        let createdAt: Date
        let failedAt: Date
        let errorDescription: String
    }

    private var pendingMutationsByID: [String: PendingMutation] = [:]
    private var failedMutationsByID: [String: FailedMutation] = [:]

    var pendingMutationCount: Int {
        pendingMutationsByID.count
    }

    var failedMutations: [FailedMutation] {
        failedMutationsByID.values.sorted { $0.failedAt > $1.failedAt }
    }

    func trackPendingMutation(_ mutation: PendingMutation) {
        pendingMutationsByID[mutation.id] = mutation
        failedMutationsByID[mutation.id] = nil
        NotificationCenter.default.post(name: .outboundSendMutationChanged, object: nil)
    }

    func reconcileSuccess(_ success: OutboundMessageReconciliationHooks.Success) {
        let removedPending = pendingMutationsByID.removeValue(forKey: success.optimisticMessageID)
        let removedFailed = failedMutationsByID.removeValue(forKey: success.optimisticMessageID)
        guard removedPending != nil || removedFailed != nil else { return }
        NotificationCenter.default.post(name: .outboundSendMutationChanged, object: nil)
    }

    func reconcileFailure(_ failure: OutboundMessageReconciliationHooks.Failure) {
        let pendingMutation = pendingMutationsByID.removeValue(forKey: failure.optimisticMessageID)
        failedMutationsByID[failure.optimisticMessageID] = FailedMutation(
            id: failure.optimisticMessageID,
            conversationObjectURI: pendingMutation?.conversationObjectURI,
            createdAt: pendingMutation?.createdAt ?? Date(),
            failedAt: Date(),
            errorDescription: failure.errorDescription
        )
        NotificationCenter.default.post(name: .outboundSendMutationChanged, object: nil)
        NotificationCenter.default.post(name: .outboundSendFailed, object: nil)
    }
}
