import Foundation

// MARK: - Action Executor Protocol

protocol ActionExecutorProtocol: Sendable {
    /// Executes a pending action.
    /// - Parameters:
    ///   - type: Action type to execute.
    ///   - messageId: Single-message target when applicable.
    ///   - sourceConversationId: Optional local conversation metadata for tracing/debugging only.
    ///     Batch action execution is driven by `payload["messageIds"]`.
    ///   - payload: Additional action data.
    func execute(
        type: PendingAction.ActionType,
        messageId: String?,
        sourceConversationId: UUID?,
        payload: [String: Any]?
    ) async throws
}

// MARK: - Gmail Action Executor

/// Executes pending actions against the Gmail API
/// Extracted from PendingActionsManager for single responsibility
actor GmailActionExecutor: ActionExecutorProtocol {
    private let apiClientProvider: @Sendable () async -> GmailAPIClient

    init(apiClientProvider: @escaping @Sendable () async -> GmailAPIClient = {
        await MainActor.run { GmailAPIClient.shared }
    }) {
        self.apiClientProvider = apiClientProvider
    }

    func execute(
        type: PendingAction.ActionType,
        messageId: String?,
        sourceConversationId: UUID?,
        payload: [String: Any]?
    ) async throws {
        // Metadata-only parameter used for traceability.
        _ = sourceConversationId
        let apiClient = await apiClientProvider()

        switch type {
        case .markRead:
            guard let messageId = messageId else {
                throw PendingActionError.missingMessageId
            }
            _ = try await apiClient.modifyMessage(id: messageId, removeLabelIds: ["UNREAD"])
            Log.diagnostic(.pendingActions, "Executed markRead for message: \(messageId)", category: .sync)

        case .markUnread:
            guard let messageId = messageId else {
                throw PendingActionError.missingMessageId
            }
            _ = try await apiClient.modifyMessage(id: messageId, addLabelIds: ["UNREAD"])
            Log.diagnostic(.pendingActions, "Executed markUnread for message: \(messageId)", category: .sync)

        case .archive:
            guard let messageId = messageId else {
                throw PendingActionError.missingMessageId
            }
            _ = try await apiClient.modifyMessage(id: messageId, removeLabelIds: ["INBOX"])
            Log.diagnostic(.pendingActions, "Executed archive for message: \(messageId)", category: .sync)

        case .archiveConversation:
            guard let messageIds = payload?["messageIds"] as? [String], !messageIds.isEmpty else {
                throw PendingActionError.missingMessageIds
            }
            try await apiClient.batchModify(ids: messageIds, removeLabelIds: ["INBOX"])
            Log.diagnostic(.pendingActions, "Executed archiveConversation for \(messageIds.count) messages", category: .sync)

        case .star:
            guard let messageId = messageId else {
                throw PendingActionError.missingMessageId
            }
            _ = try await apiClient.modifyMessage(id: messageId, addLabelIds: ["STARRED"])
            Log.diagnostic(.pendingActions, "Executed star for message: \(messageId)", category: .sync)

        case .unstar:
            guard let messageId = messageId else {
                throw PendingActionError.missingMessageId
            }
            _ = try await apiClient.modifyMessage(id: messageId, removeLabelIds: ["STARRED"])
            Log.diagnostic(.pendingActions, "Executed unstar for message: \(messageId)", category: .sync)

        case .reportSpam:
            guard let messageIds = payload?["messageIds"] as? [String], !messageIds.isEmpty else {
                throw PendingActionError.missingMessageIds
            }
            // Add SPAM label AND remove INBOX label (matches Gmail behavior)
            try await apiClient.batchModify(ids: messageIds, addLabelIds: ["SPAM"], removeLabelIds: ["INBOX"])
            Log.diagnostic(.pendingActions, "Executed reportSpam for \(messageIds.count) messages", category: .sync)
        }
    }
}

// MARK: - Pending Action Error

enum PendingActionError: LocalizedError {
    case invalidActionType
    case missingMessageId
    case missingMessageIds
    case missingConversationId

    var errorDescription: String? {
        switch self {
        case .invalidActionType:
            return "Invalid action type"
        case .missingMessageId:
            return "Message ID is required for this action"
        case .missingMessageIds:
            return "Message IDs are required for this action"
        case .missingConversationId:
            return "Conversation ID is required for this action"
        }
    }
}

// MARK: - Mock Action Executor for Testing

#if DEBUG
actor MockActionExecutor: ActionExecutorProtocol {
    var executedActions: [(type: PendingAction.ActionType, messageId: String?, sourceConversationId: UUID?, payload: [String: Any]?)] = []
    var shouldFail = false

    func execute(
        type: PendingAction.ActionType,
        messageId: String?,
        sourceConversationId: UUID?,
        payload: [String: Any]?
    ) async throws {
        _ = sourceConversationId
        if shouldFail {
            throw PendingActionError.invalidActionType
        }
        executedActions.append((type, messageId, sourceConversationId, payload))
    }
}
#endif
