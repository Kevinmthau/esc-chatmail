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
        try await getMessage(id: id, format: format, maxRetries: nil)
    }

    /// Retry-budgeted fetch: threads `maxRetries` (total attempts; nil = the
    /// configured strategy) into the retry loop so callers owning their own
    /// retry policy (MessageFetcher) can collapse the stacked loops.
    nonisolated func getMessage(id: String, format: String, maxRetries: Int?) async throws -> GmailMessage {
        let url = try buildURL(
            endpoint: APIEndpoints.message(id: id),
            queryItems: [URLQueryItem(name: "format", value: format)]
        )
        let request = try await authenticatedRequest(url: url)
        return try await performRequestWithRetry(request, maxRetries: maxRetries)
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

    /// Sends a MIME-encoded raw message.
    nonisolated func sendMessage(rawMessage: String, threadId: String? = nil) async throws -> SendMessageResponse {
        let url = try buildURL(endpoint: APIEndpoints.sendMessage())
        var request = try await authenticatedRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = try JSONEncoder().encode(
            SendMessageRequest(raw: rawMessage, threadId: threadId)
        )

        // Sending is not idempotent and Gmail has no idempotency key: resending after
        // an ambiguous failure (timeout, 5xx) could deliver the email twice.
        return try await performRequestWithRetry(request, allowsRetransmission: false)
    }

    /// Archives messages by removing the INBOX label.
    nonisolated func archiveMessages(ids: [String]) async throws {
        try await batchModify(ids: ids, removeLabelIds: ["INBOX"])
    }
}
