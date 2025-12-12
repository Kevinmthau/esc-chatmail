import Foundation

enum APIError: LocalizedError {
    case invalidURL(String)
    case networkError(Error)
    case decodingError(Error)
    case authenticationError
    case rateLimited
    case serverError(Int)
    case timeout
    case historyIdExpired
    case notFound(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL(let url):
            return "Invalid URL: \(url)"
        case .networkError(let error):
            return "Network error: \(error.localizedDescription)"
        case .decodingError(let error):
            return "Failed to decode response: \(error.localizedDescription)"
        case .authenticationError:
            return "Authentication failed"
        case .rateLimited:
            return "Rate limited by server"
        case .serverError(let code):
            return "Server error: \(code)"
        case .timeout:
            return "Request timed out"
        case .historyIdExpired:
            return "History ID has expired. A full sync is required."
        case .notFound(let resource):
            return "Resource not found: \(resource)"
        }
    }
}

/// Wraps an async operation with a timeout
func withTimeout<T: Sendable>(seconds: TimeInterval, operation: @Sendable @escaping () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask {
            try await operation()
        }

        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw APIError.timeout
        }

        // Return the first result (either success or timeout)
        guard let result = try await group.next() else {
            throw APIError.timeout
        }
        group.cancelAll()
        return result
    }
}

@MainActor
class GmailAPIClient {
    static let shared = GmailAPIClient()
    private let session: URLSession
    private let tokenManager = TokenManager.shared

    private init() {
        // Configure URLSession with timeout and retry settings
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = NetworkConfig.requestTimeout
        configuration.timeoutIntervalForResource = NetworkConfig.resourceTimeout
        configuration.waitsForConnectivity = true // Wait for network connectivity
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData

        self.session = URLSession(configuration: configuration)
    }

    private nonisolated func authenticatedRequest(url: URL) async throws -> URLRequest {
        // Validate URL before creating request
        guard isValidURL(url) else {
            throw APIError.invalidURL(url.absoluteString)
        }

        var request = URLRequest(url: url)
        // Use TokenManager with automatic retry on auth failure
        let token = try await tokenManager.getCurrentToken()
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return request
    }

    private nonisolated func isValidURL(_ url: URL) -> Bool {
        // Check for valid scheme
        guard let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme) else {
            return false
        }

        // Check for valid host
        guard let host = url.host, !host.isEmpty else {
            return false
        }

        // Check URL string is not malformed
        let urlString = url.absoluteString
        if urlString.isEmpty || urlString.contains(" ") {
            return false
        }

        return true
    }
    
    private nonisolated func performRequestWithRetry<T: Decodable>(_ request: URLRequest, maxRetries: Int = NetworkConfig.maxRetries) async throws -> T {
        var lastError: Error?
        var retryDelay: TimeInterval = NetworkConfig.initialRetryDelay

        // Validate request URL
        guard let url = request.url, isValidURL(url) else {
            throw APIError.invalidURL(request.url?.absoluteString ?? "unknown")
        }

        for attempt in 0..<maxRetries {
            do {
                let (data, response) = try await session.data(for: request)
                
                // Check for HTTP errors
                if let httpResponse = response as? HTTPURLResponse {
                    if httpResponse.statusCode == 429 {
                        // Rate limited - wait longer
                        let delay = retryDelay * 2
                        print("Rate limited, waiting \(delay) seconds before retry")
                        try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                        retryDelay = min(delay * 2, NetworkConfig.maxRetryDelay)
                        continue
                    } else if httpResponse.statusCode >= 500 {
                        // Server error - retry with backoff
                        print("Server error \(httpResponse.statusCode), attempt \(attempt + 1) of \(maxRetries)")
                        if attempt < maxRetries - 1 {
                            try await Task.sleep(nanoseconds: UInt64(retryDelay * 1_000_000_000))
                            retryDelay = min(retryDelay * 2, NetworkConfig.maxRetryDelay)
                            continue
                        }
                    }

                    // Handle empty response for void-like operations (e.g., batchModify returns 204 No Content)
                    if (200...299).contains(httpResponse.statusCode) && data.isEmpty {
                        if let empty = EmptyResponse() as? T {
                            return empty
                        }
                    }
                }

                return try JSONDecoder().decode(T.self, from: data)
            } catch {
                lastError = error
                print("Request failed (attempt \(attempt + 1)): \(error.localizedDescription)")
                
                // Check if it's a network error
                if let urlError = error as? URLError {
                    switch urlError.code {
                    case .notConnectedToInternet, .networkConnectionLost, .timedOut, .cannotFindHost, .dnsLookupFailed:
                        if attempt < maxRetries - 1 {
                            print("Network error, retrying in \(retryDelay) seconds...")
                            try await Task.sleep(nanoseconds: UInt64(retryDelay * 1_000_000_000))
                            retryDelay = min(retryDelay * 2, NetworkConfig.maxRetryDelay)
                            continue
                        }
                    case .unsupportedURL:
                        // Don't retry unsupported URLs
                        print("Unsupported URL error - not retrying")
                        throw APIError.invalidURL(request.url?.absoluteString ?? "unknown")
                    default:
                        throw error
                    }
                }
                
                if attempt == maxRetries - 1 {
                    throw lastError ?? error
                }
            }
        }
        
        throw lastError ?? URLError(.unknown)
    }
    
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
        // Archive by removing INBOX label
        try await batchModify(ids: ids, removeLabelIds: ["INBOX"])
    }

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
        // Gmail returns 404 when the historyId is too old/expired
        return try await performHistoryRequest(request)
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
            // Try to parse the error response for more details
            if let errorResponse = try? JSONDecoder().decode(GmailErrorResponse.self, from: data) {
                let errorMessage = errorResponse.error.message.lowercased()
                if errorMessage.contains("not found") ||
                   errorMessage.contains("invalid") ||
                   errorMessage.contains("too old") {
                    print("History ID expired: \(errorResponse.error.message)")
                    throw APIError.historyIdExpired
                }
            }
            // Default to historyIdExpired for any 404 on history endpoint
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

    nonisolated func listSendAs() async throws -> [SendAs] {
        let endpoint = APIEndpoints.sendAs()
        guard let url = URL(string: endpoint) else {
            throw APIError.invalidURL(endpoint)
        }
        let request = try await authenticatedRequest(url: url)
        let response: SendAsListResponse = try await performRequestWithRetry(request)
        return response.sendAs ?? []
    }

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

    // MARK: - People API

    /// Search for a person by email address using the Google People API
    nonisolated func searchPeopleByEmail(email: String) async throws -> PeopleSearchResult {
        let endpoint = PeopleAPIEndpoints.searchContacts(query: email)
        guard let url = URL(string: endpoint) else {
            throw APIError.invalidURL(endpoint)
        }

        let request = try await authenticatedRequest(url: url)
        let response: PeopleSearchResponse = try await performRequestWithRetry(request)

        // Find the best match from results
        if let results = response.results {
            for result in results {
                if let person = result.person {
                    // Check if email matches
                    let personEmails = person.emailAddresses?.map { $0.value.lowercased() } ?? []
                    if personEmails.contains(email.lowercased()) {
                        // Get the best photo URL
                        let photoURL = person.photos?.first(where: { $0.metadata?.primary == true })?.url
                            ?? person.photos?.first?.url

                        let displayName = person.names?.first?.displayName

                        return PeopleSearchResult(
                            email: email,
                            displayName: displayName,
                            photoURL: photoURL
                        )
                    }
                }
            }
        }

        // No match found
        return PeopleSearchResult(email: email, displayName: nil, photoURL: nil)
    }
}

// MARK: - Helper Response Types

/// Empty response for endpoints that don't return data
private struct EmptyResponse: Codable {}

/// Gmail API error response structure
private struct GmailErrorResponse: Codable {
    let error: GmailErrorDetail

    struct GmailErrorDetail: Codable {
        let code: Int
        let message: String
        let status: String?
    }
}

/// Response type for attachment data
private struct AttachmentResponse: Codable {
    let size: Int?
    let data: String
}

extension Data {
    init?(base64UrlEncoded: String) {
        var base64 = base64UrlEncoded
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        
        while base64.count % 4 != 0 {
            base64.append("=")
        }
        
        self.init(base64Encoded: base64)
    }
    
    func base64UrlEncodedString() -> String {
        return self.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

struct GmailProfile: Codable {
    let emailAddress: String
    let messagesTotal: Int?
    let threadsTotal: Int?
    let historyId: String
}

struct GmailLabel: Codable {
    let id: String
    let name: String
    let messageListVisibility: String?
    let labelListVisibility: String?
    let type: String?
}

struct LabelsResponse: Codable {
    let labels: [GmailLabel]?
}

struct MessagesListResponse: Codable {
    let messages: [MessageListItem]?
    let nextPageToken: String?
    let resultSizeEstimate: Int?
}

struct MessageListItem: Codable {
    let id: String
    let threadId: String?
}

struct GmailMessage: Codable {
    let id: String
    let threadId: String?
    let labelIds: [String]?
    let snippet: String?
    let historyId: String?
    let internalDate: String?
    let payload: MessagePart?
    let sizeEstimate: Int?
}

struct MessagePart: Codable {
    let partId: String?
    let mimeType: String?
    let filename: String?
    let headers: [MessageHeader]?
    let body: MessageBody?
    let parts: [MessagePart]?
}

struct MessageHeader: Codable {
    let name: String
    let value: String
}

struct MessageBody: Codable {
    let size: Int?
    let data: String?
    let attachmentId: String?
}

struct ModifyMessageRequest: Codable {
    let addLabelIds: [String]?
    let removeLabelIds: [String]?
}

struct BatchModifyRequest: Codable {
    let ids: [String]
    let addLabelIds: [String]?
    let removeLabelIds: [String]?
}

struct HistoryResponse: Codable {
    let history: [HistoryRecord]?
    let nextPageToken: String?
    let historyId: String?
}

struct HistoryRecord: Codable {
    let id: String
    let messages: [GmailMessage]?
    let messagesAdded: [HistoryMessageAdded]?
    let messagesDeleted: [HistoryMessageDeleted]?
    let labelsAdded: [HistoryLabelAdded]?
    let labelsRemoved: [HistoryLabelRemoved]?
}

struct HistoryMessageAdded: Codable {
    let message: GmailMessage
}

struct HistoryMessageDeleted: Codable {
    let message: MessageListItem
}

struct HistoryLabelAdded: Codable {
    let message: MessageListItem
    let labelIds: [String]
}

struct HistoryLabelRemoved: Codable {
    let message: MessageListItem
    let labelIds: [String]
}

struct SendAsListResponse: Codable {
    let sendAs: [SendAs]?
}

struct SendAs: Codable {
    let sendAsEmail: String
    let displayName: String?
    let replyToAddress: String?
    let signature: String?
    let isPrimary: Bool?
    let isDefault: Bool?
    let treatAsAlias: Bool?
    let verificationStatus: String?
}

// MARK: - People API Response Types

struct PeopleSearchResult {
    let email: String
    let displayName: String?
    let photoURL: String?
}

struct PeopleSearchResponse: Codable {
    let results: [PersonSearchResult]?
}

struct PersonSearchResult: Codable {
    let person: GooglePerson?
}

struct GooglePerson: Codable {
    let resourceName: String?
    let etag: String?
    let names: [GooglePersonName]?
    let photos: [GooglePersonPhoto]?
    let emailAddresses: [GooglePersonEmail]?
}

struct GooglePersonName: Codable {
    let displayName: String?
    let familyName: String?
    let givenName: String?
    let metadata: GooglePersonMetadata?
}

struct GooglePersonPhoto: Codable {
    let url: String?
    let metadata: GooglePersonMetadata?
}

struct GooglePersonEmail: Codable {
    let value: String
    let type: String?
    let metadata: GooglePersonMetadata?
}

struct GooglePersonMetadata: Codable {
    let primary: Bool?
    let source: GooglePersonSource?
}

struct GooglePersonSource: Codable {
    let type: String?
    let id: String?
}