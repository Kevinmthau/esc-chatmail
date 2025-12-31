import Foundation

// MARK: - Gmail API Client

/// Client for Gmail API operations
/// Error types, retry logic, and People API have been extracted to separate files
@MainActor
class GmailAPIClient {
    static let shared = GmailAPIClient()

    private let session: URLSession
    private let tokenManager: TokenManagerProtocol
    private let retryStrategy: RetryStrategy

    /// Production initializer - uses shared TokenManager
    private init() {
        self.tokenManager = TokenManager.shared
        self.retryStrategy = NetworkRetryStrategy()
        self.session = Self.createSession()
    }

    /// Testable initializer - accepts custom dependencies
    init(tokenManager: TokenManagerProtocol, retryStrategy: RetryStrategy = NetworkRetryStrategy()) {
        self.tokenManager = tokenManager
        self.retryStrategy = retryStrategy
        self.session = Self.createSession()
    }

    private static func createSession() -> URLSession {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = max(NetworkConfig.requestTimeout, 30.0)
        configuration.timeoutIntervalForResource = NetworkConfig.resourceTimeout
        configuration.waitsForConnectivity = true
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration)
    }

    // MARK: - Profile & Labels

    nonisolated func getProfile() async throws -> GmailProfile {
        guard let url = URL(string: APIEndpoints.profile()) else {
            throw APIError.invalidURL(APIEndpoints.profile())
        }
        let request = try await authenticatedRequest(url: url)
        return try await performRequestWithRetry(request)
    }

    nonisolated func listLabels() async throws -> [GmailLabel] {
        guard let url = URL(string: APIEndpoints.labels()) else {
            throw APIError.invalidURL(APIEndpoints.labels())
        }
        let request = try await authenticatedRequest(url: url)
        let response: LabelsResponse = try await performRequestWithRetry(request)
        return response.labels ?? []
    }

    // MARK: - Messages

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

    nonisolated func archiveMessages(ids: [String]) async throws {
        try await batchModify(ids: ids, removeLabelIds: ["INBOX"])
    }

    // MARK: - History

    nonisolated func listHistory(startHistoryId: String, pageToken: String? = nil) async throws -> HistoryResponse {
        let endpoint = APIEndpoints.history()
        guard var components = URLComponents(string: endpoint) else {
            throw APIError.invalidURL(endpoint)
        }
        components.queryItems = [
            URLQueryItem(name: "startHistoryId", value: startHistoryId)
        ]
        if let pageToken = pageToken {
            components.queryItems?.append(URLQueryItem(name: "pageToken", value: pageToken))
        }

        guard let url = components.url else {
            throw APIError.invalidURL(endpoint)
        }
        let request = try await authenticatedRequest(url: url)

        // Use specialized error handling for history API
        return try await performHistoryRequest(request)
    }

    // MARK: - Send As (Aliases)

    nonisolated func listSendAs() async throws -> [SendAs] {
        let endpoint = APIEndpoints.sendAs()
        guard let url = URL(string: endpoint) else {
            throw APIError.invalidURL(endpoint)
        }
        let request = try await authenticatedRequest(url: url)
        let response: SendAsListResponse = try await performRequestWithRetry(request)
        return response.sendAs ?? []
    }

    // MARK: - Attachments

    nonisolated func getAttachment(messageId: String, attachmentId: String) async throws -> Data {
        let endpoint = APIEndpoints.attachment(messageId: messageId, attachmentId: attachmentId)
        guard let url = URL(string: endpoint) else {
            throw APIError.invalidURL(endpoint)
        }
        let request = try await authenticatedRequest(url: url)
        let response: AttachmentResponse = try await performRequestWithRetry(request)

        guard let attachmentData = Data(base64UrlEncoded: response.data) else {
            throw NSError(domain: "GmailAPI", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to decode attachment data"])
        }

        return attachmentData
    }

    // MARK: - Private Helpers

    private nonisolated func authenticatedRequest(url: URL) async throws -> URLRequest {
        guard isValidURL(url) else {
            throw APIError.invalidURL(url.absoluteString)
        }

        var request = URLRequest(url: url)

        // Disable HTTP/3 (QUIC) to avoid connection errors
        if #available(iOS 14.5, *) {
            request.assumesHTTP3Capable = false
        }

        let token = try await tokenManager.getCurrentToken()
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return request
    }

    private nonisolated func isValidURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme) else {
            return false
        }

        guard let host = url.host, !host.isEmpty else {
            return false
        }

        let urlString = url.absoluteString
        return !urlString.isEmpty && !urlString.contains(" ")
    }

    private nonisolated func performRequestWithRetry<T: Decodable>(_ request: URLRequest, maxRetries: Int? = nil) async throws -> T {
        let retries = maxRetries ?? retryStrategy.maxRetries
        var lastError: Error?
        var retryDelay = retryStrategy.initialDelay

        for attempt in 0..<retries {
            do {
                let (data, response) = try await session.data(for: request)

                if let httpResponse = response as? HTTPURLResponse {
                    switch httpResponse.statusCode {
                    case 429:
                        let delay = retryDelay * 2
                        Log.warning("Rate limited, waiting \(delay) seconds before retry", category: .api)
                        try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                        retryDelay = min(delay * 2, retryStrategy.maxDelay)
                        continue

                    case 500...599:
                        Log.warning("Server error \(httpResponse.statusCode), attempt \(attempt + 1)/\(retries)", category: .api)
                        if attempt < retries - 1 {
                            try await Task.sleep(nanoseconds: UInt64(retryDelay * 1_000_000_000))
                            retryDelay = min(retryDelay * 2, retryStrategy.maxDelay)
                            continue
                        }

                    case 401:
                        throw APIError.authenticationError

                    case 200...299 where data.isEmpty:
                        if let empty = EmptyResponse() as? T {
                            return empty
                        }

                    default:
                        break
                    }
                }

                return try JSONDecoder().decode(T.self, from: data)

            } catch {
                lastError = error
                Log.error("Request failed (attempt \(attempt + 1)/\(retries)): \(error.localizedDescription)", category: .api)

                if !retryStrategy.shouldRetry(error: error, attempt: attempt) {
                    if error is DecodingError {
                        throw APIError.decodingError(error)
                    }
                    throw error
                }

                if attempt < retries - 1 {
                    Log.info("Retrying in \(retryDelay) seconds...", category: .api)
                    try await Task.sleep(nanoseconds: UInt64(retryDelay * 1_000_000_000))
                    retryDelay = min(retryDelay * 2, retryStrategy.maxDelay)
                }
            }
        }

        throw lastError ?? URLError(.unknown)
    }

    /// Specialized request handler for history API that detects expired history IDs
    private nonisolated func performHistoryRequest(_ request: URLRequest) async throws -> HistoryResponse {
        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.networkError(URLError(.badServerResponse))
        }

        switch httpResponse.statusCode {
        case 200:
            return try JSONDecoder().decode(HistoryResponse.self, from: data)

        case 404:
            // Gmail returns 404 when historyId is expired or invalid
            if let errorResponse = try? JSONDecoder().decode(GmailErrorResponse.self, from: data) {
                let errorMessage = errorResponse.error.message.lowercased()
                if errorMessage.contains("not found") ||
                   errorMessage.contains("invalid") ||
                   errorMessage.contains("too old") {
                    Log.warning("History ID expired: \(errorResponse.error.message)", category: .api)
                    throw APIError.historyIdExpired
                }
            }
            throw APIError.historyIdExpired

        case 401:
            throw APIError.authenticationError

        case 429:
            throw APIError.rateLimited

        case 500...599:
            throw APIError.serverError(httpResponse.statusCode)

        default:
            throw APIError.serverError(httpResponse.statusCode)
        }
    }
}
