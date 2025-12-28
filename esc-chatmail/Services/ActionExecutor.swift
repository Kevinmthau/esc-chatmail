import Foundation

// MARK: - Action Executor Protocol

protocol ActionExecutorProtocol: Sendable {
    func execute(
        type: PendingAction.ActionType,
        messageId: String?,
        conversationId: UUID?,
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
        conversationId: UUID?,
        payload: [String: Any]?
    ) async throws {
        let apiClient = await apiClientProvider()

        switch type {
        case .markRead:
            guard let messageId = messageId else {
                throw PendingActionError.missingMessageId
            }
            _ = try await apiClient.modifyMessage(id: messageId, removeLabelIds: ["UNREAD"])
            Log.debug("Executed markRead for message: \(messageId)", category: .sync)

        case .markUnread:
            guard let messageId = messageId else {
                throw PendingActionError.missingMessageId
            }
            _ = try await apiClient.modifyMessage(id: messageId, addLabelIds: ["UNREAD"])
            Log.debug("Executed markUnread for message: \(messageId)", category: .sync)

        case .archive:
            guard let messageId = messageId else {
                throw PendingActionError.missingMessageId
            }
            _ = try await apiClient.modifyMessage(id: messageId, removeLabelIds: ["INBOX"])
            Log.debug("Executed archive for message: \(messageId)", category: .sync)

        case .archiveConversation:
            guard let messageIds = payload?["messageIds"] as? [String], !messageIds.isEmpty else {
                throw PendingActionError.missingMessageIds
            }
            try await apiClient.batchModify(ids: messageIds, removeLabelIds: ["INBOX"])
            Log.debug("Executed archiveConversation for \(messageIds.count) messages", category: .sync)

        case .star:
            guard let messageId = messageId else {
                throw PendingActionError.missingMessageId
            }
            _ = try await apiClient.modifyMessage(id: messageId, addLabelIds: ["STARRED"])
            Log.debug("Executed star for message: \(messageId)", category: .sync)

        case .unstar:
            guard let messageId = messageId else {
                throw PendingActionError.missingMessageId
            }
            _ = try await apiClient.modifyMessage(id: messageId, removeLabelIds: ["STARRED"])
            Log.debug("Executed unstar for message: \(messageId)", category: .sync)
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
    var executedActions: [(type: PendingAction.ActionType, messageId: String?, payload: [String: Any]?)] = []
    var shouldFail = false

    func execute(
        type: PendingAction.ActionType,
        messageId: String?,
        conversationId: UUID?,
        payload: [String: Any]?
    ) async throws {
        if shouldFail {
            throw PendingActionError.invalidActionType
        }
        executedActions.append((type, messageId, payload))
    }
}
#endif
