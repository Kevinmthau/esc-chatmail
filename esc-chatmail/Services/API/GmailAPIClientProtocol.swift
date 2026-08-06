import Foundation

/// Protocol defining the Gmail API client interface.
/// Enables dependency injection and testing with mock implementations.
protocol GmailAPIClientProtocol: AnyObject, Sendable {

    // MARK: - Messages API

    /// Lists messages in the mailbox.
    func listMessages(pageToken: String?, maxResults: Int, query: String?) async throws -> MessagesListResponse

    /// Fetches a single message by ID.
    func getMessage(id: String, format: String) async throws -> GmailMessage

    /// Fetches a single message by ID with an explicit retry budget.
    ///
    /// `maxRetries` means TOTAL attempts (the client's loop runs
    /// `while attempt < allowedAttempts`), not retries after the first try;
    /// nil uses the client's configured strategy. A successful 401 token
    /// refresh grants a replacement attempt and never consumes the budget.
    ///
    /// A protocol requirement (not extension-only) deliberately: an
    /// extension method would be statically dispatched through
    /// `any GmailAPIClientProtocol` and the budget would silently no-op
    /// for the real client.
    func getMessage(id: String, format: String, maxRetries: Int?) async throws -> GmailMessage

    /// Modifies a message's labels.
    func modifyMessage(id: String, addLabelIds: [String]?, removeLabelIds: [String]?) async throws -> GmailMessage

    /// Batch modifies multiple messages.
    func batchModify(ids: [String], addLabelIds: [String]?, removeLabelIds: [String]?) async throws

    /// Archives messages by removing the INBOX label.
    func archiveMessages(ids: [String]) async throws

    /// Sends a MIME-encoded raw message.
    func sendMessage(rawMessage: String, threadId: String?) async throws -> SendMessageResponse

    // MARK: - Profile, Labels & Aliases API

    /// Fetches the user's profile.
    func getProfile() async throws -> GmailProfile

    /// Lists all labels in the mailbox.
    func listLabels() async throws -> [GmailLabel]

    /// Lists configured send-as aliases.
    func listSendAs() async throws -> [SendAs]

    // MARK: - History API

    /// Lists history changes since a given history ID.
    /// - Parameter maxResults: Caps history RECORDS per page (not messages —
    ///   one record can still fan out into many message fetches). `nil` uses
    ///   the server default.
    func listHistory(startHistoryId: String, pageToken: String?, maxResults: Int?) async throws -> HistoryResponse

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

    /// Default witness for conformers without retry budgets (mocks, fakes):
    /// forwards to the 2-arg fetch, ignoring `maxRetries`.
    func getMessage(id: String, format: String, maxRetries: Int?) async throws -> GmailMessage {
        try await getMessage(id: id, format: format)
    }

    func modifyMessage(id: String, addLabelIds: [String]? = nil, removeLabelIds: [String]? = nil) async throws -> GmailMessage {
        try await modifyMessage(id: id, addLabelIds: addLabelIds, removeLabelIds: removeLabelIds)
    }

    func batchModify(ids: [String], addLabelIds: [String]? = nil, removeLabelIds: [String]? = nil) async throws {
        try await batchModify(ids: ids, addLabelIds: addLabelIds, removeLabelIds: removeLabelIds)
    }

    func sendMessage(rawMessage: String, threadId: String? = nil) async throws -> SendMessageResponse {
        try await sendMessage(rawMessage: rawMessage, threadId: threadId)
    }

    func listHistory(startHistoryId: String, pageToken: String? = nil, maxResults: Int? = nil) async throws -> HistoryResponse {
        try await listHistory(startHistoryId: startHistoryId, pageToken: pageToken, maxResults: maxResults)
    }
}
