import Foundation

// MARK: - Messages API

extension GmailAPIClient {

    /// Lists messages in the mailbox.
    nonisolated func listMessages(pageToken: String? = nil, maxResults: Int = 100, query: String? = nil) async throws -> MessagesListResponse {
        var queryItems = [URLQueryItem(name: "maxResults", value: String(maxResults))]
        if let pageToken = pageToken {
            queryItems.append(URLQueryItem(name: "pageToken", value: pageToken))
        }
        if let query = query {
            queryItems.append(URLQueryItem(name: "q", value: query))
        }
        return try await performGET(endpoint: APIEndpoints.messages(), queryItems: queryItems)
    }

    /// Fetches a single message by ID.
    nonisolated func getMessage(id: String, format: String = "full") async throws -> GmailMessage {
        try await performGET(
            endpoint: APIEndpoints.message(id: id),
            queryItems: [URLQueryItem(name: "format", value: format)]
        )
    }

    /// Modifies a message's labels.
    nonisolated func modifyMessage(id: String, addLabelIds: [String]? = nil, removeLabelIds: [String]? = nil) async throws -> GmailMessage {
        let url = try buildURL(endpoint: APIEndpoints.modifyMessage(id: id))
        var request = try await authenticatedRequest(url: url)
        request.httpMethod = "POST"

        let body = ModifyMessageRequest(addLabelIds: addLabelIds, removeLabelIds: removeLabelIds)
        request.httpBody = try JSONEncoder().encode(body)

        return try await performRequestWithRetry(request)
    }

    /// Batch modifies multiple messages.
    nonisolated func batchModify(ids: [String], addLabelIds: [String]? = nil, removeLabelIds: [String]? = nil) async throws {
        let url = try buildURL(endpoint: APIEndpoints.batchModify())
        var request = try await authenticatedRequest(url: url)
        request.httpMethod = "POST"

        let body = BatchModifyRequest(ids: ids, addLabelIds: addLabelIds, removeLabelIds: removeLabelIds)
        request.httpBody = try JSONEncoder().encode(body)

        let _: EmptyResponse = try await performRequestWithRetry(request)
    }

    /// Archives messages by removing the INBOX label.
    nonisolated func archiveMessages(ids: [String]) async throws {
        try await batchModify(ids: ids, removeLabelIds: ["INBOX"])
    }
}
