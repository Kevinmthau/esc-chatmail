import Foundation

// MARK: - Messages API

extension GmailAPIClient {

    /// Lists messages in the mailbox.
    nonisolated func listMessages(pageToken: String? = nil, maxResults: Int = 100, query: String? = nil) async throws -> MessagesListResponse {
        guard var components = URLComponents(string: APIEndpoints.messages()) else {
            throw APIError.invalidURL(APIEndpoints.messages())
        }
        components.queryItems = [
            URLQueryItem(name: "maxResults", value: String(maxResults))
        ]
        if let pageToken = pageToken {
            components.queryItems?.append(URLQueryItem(name: "pageToken", value: pageToken))
        }
        if let query = query {
            components.queryItems?.append(URLQueryItem(name: "q", value: query))
        }

        guard let url = components.url else {
            throw APIError.invalidURL(APIEndpoints.messages())
        }
        let request = try await authenticatedRequest(url: url)
        return try await performRequestWithRetry(request)
    }

    /// Fetches a single message by ID.
    nonisolated func getMessage(id: String, format: String = "full") async throws -> GmailMessage {
        let endpoint = APIEndpoints.message(id: id)
        guard var components = URLComponents(string: endpoint) else {
            throw APIError.invalidURL(endpoint)
        }
        components.queryItems = [URLQueryItem(name: "format", value: format)]

        guard let url = components.url else {
            throw APIError.invalidURL(endpoint)
        }
        let request = try await authenticatedRequest(url: url)
        return try await performRequestWithRetry(request)
    }

    /// Modifies a message's labels.
    nonisolated func modifyMessage(id: String, addLabelIds: [String]? = nil, removeLabelIds: [String]? = nil) async throws -> GmailMessage {
        let endpoint = APIEndpoints.modifyMessage(id: id)
        guard let url = URL(string: endpoint) else {
            throw APIError.invalidURL(endpoint)
        }
        var request = try await authenticatedRequest(url: url)
        request.httpMethod = "POST"

        let body = ModifyMessageRequest(addLabelIds: addLabelIds, removeLabelIds: removeLabelIds)
        request.httpBody = try JSONEncoder().encode(body)

        return try await performRequestWithRetry(request)
    }

    /// Batch modifies multiple messages.
    nonisolated func batchModify(ids: [String], addLabelIds: [String]? = nil, removeLabelIds: [String]? = nil) async throws {
        let endpoint = APIEndpoints.batchModify()
        guard let url = URL(string: endpoint) else {
            throw APIError.invalidURL(endpoint)
        }
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
