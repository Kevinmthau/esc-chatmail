import Foundation

/// Protocol defining the Gmail API client interface.
/// Enables dependency injection and testing with mock implementations.
protocol GmailAPIClientProtocol: AnyObject, Sendable {

    // MARK: - Messages API

    /// Lists messages in the mailbox.
    func listMessages(pageToken: String?, maxResults: Int, query: String?) async throws -> MessagesListResponse

    /// Fetches a single message by ID.
    func getMessage(id: String, format: String) async throws -> GmailMessage

    /// Modifies a message's labels.
    func modifyMessage(id: String, addLabelIds: [String]?, removeLabelIds: [String]?) async throws -> GmailMessage

    /// Batch modifies multiple messages.
    func batchModify(ids: [String], addLabelIds: [String]?, removeLabelIds: [String]?) async throws

    /// Archives messages by removing the INBOX label.
    func archiveMessages(ids: [String]) async throws

    // MARK: - Profile, Labels & Aliases API

    /// Fetches the user's profile.
    func getProfile() async throws -> GmailProfile

    /// Lists all labels in the mailbox.
    func listLabels() async throws -> [GmailLabel]

    /// Lists configured send-as aliases.
    func listSendAs() async throws -> [SendAs]

    // MARK: - History API

    /// Lists history changes since a given history ID.
    func listHistory(startHistoryId: String, pageToken: String?) async throws -> HistoryResponse

    // MARK: - Attachments API

    /// Fetches attachment data for a message.
    func getAttachment(messageId: String, attachmentId: String) async throws -> Data
}

// MARK: - Default Parameter Values

extension GmailAPIClientProtocol {
    func listMessages(pageToken: String? = nil, maxResults: Int = 100, query: String? = nil) async throws -> MessagesListResponse {
        try await listMessages(pageToken: pageToken, maxResults: maxResults, query: query)
    }

    func getMessage(id: String, format: String = "full") async throws -> GmailMessage {
        try await getMessage(id: id, format: format)
    }

    func modifyMessage(id: String, addLabelIds: [String]? = nil, removeLabelIds: [String]? = nil) async throws -> GmailMessage {
        try await modifyMessage(id: id, addLabelIds: addLabelIds, removeLabelIds: removeLabelIds)
    }

    func batchModify(ids: [String], addLabelIds: [String]? = nil, removeLabelIds: [String]? = nil) async throws {
        try await batchModify(ids: ids, addLabelIds: addLabelIds, removeLabelIds: removeLabelIds)
    }

    func listHistory(startHistoryId: String, pageToken: String? = nil) async throws -> HistoryResponse {
        try await listHistory(startHistoryId: startHistoryId, pageToken: pageToken)
    }
}

