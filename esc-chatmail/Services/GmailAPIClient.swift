import Foundation

enum APIError: LocalizedError {
    case invalidURL(String)
    case networkError(Error)
    case decodingError(Error)
    case authenticationError
    case rateLimited
    case serverError(Int)

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
        }
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
        configuration.timeoutIntervalForRequest = 30.0  // 30 second timeout
        configuration.timeoutIntervalForResource = 60.0 // 60 second resource timeout
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
    
    private nonisolated func performRequestWithRetry<T: Decodable>(_ request: URLRequest, maxRetries: Int = 3) async throws -> T {
        var lastError: Error?
        var retryDelay: TimeInterval = 1.0

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
                        retryDelay = min(delay * 2, 30.0) // Cap at 30 seconds
                        continue
                    } else if httpResponse.statusCode >= 500 {
                        // Server error - retry with backoff
                        print("Server error \(httpResponse.statusCode), attempt \(attempt + 1) of \(maxRetries)")
                        if attempt < maxRetries - 1 {
                            try await Task.sleep(nanoseconds: UInt64(retryDelay * 1_000_000_000))
                            retryDelay = min(retryDelay * 2, 10.0) // Exponential backoff
                            continue
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
                            retryDelay = min(retryDelay * 2, 10.0)
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
        let url = URL(string: APIEndpoints.profile())!
        let request = try await authenticatedRequest(url: url)
        return try await performRequestWithRetry(request)
    }
    
    nonisolated func listLabels() async throws -> [GmailLabel] {
        let url = URL(string: APIEndpoints.labels())!
        let request = try await authenticatedRequest(url: url)
        let response: LabelsResponse = try await performRequestWithRetry(request)
        return response.labels ?? []
    }
    
    nonisolated func listMessages(pageToken: String? = nil, maxResults: Int = 100, query: String? = nil) async throws -> MessagesListResponse {
        var components = URLComponents(string: APIEndpoints.messages())!
        components.queryItems = [
            URLQueryItem(name: "maxResults", value: String(maxResults))
        ]
        if let pageToken = pageToken {
            components.queryItems?.append(URLQueryItem(name: "pageToken", value: pageToken))
        }
        if let query = query {
            components.queryItems?.append(URLQueryItem(name: "q", value: query))
        }

        let request = try await authenticatedRequest(url: components.url!)
        return try await performRequestWithRetry(request)
    }
    
    nonisolated func getMessage(id: String, format: String = "full") async throws -> GmailMessage {
        var components = URLComponents(string: APIEndpoints.message(id: id))!
        components.queryItems = [URLQueryItem(name: "format", value: format)]
        
        let request = try await authenticatedRequest(url: components.url!)
        return try await performRequestWithRetry(request)
    }
    
    nonisolated func modifyMessage(id: String, addLabelIds: [String]? = nil, removeLabelIds: [String]? = nil) async throws -> GmailMessage {
        let url = URL(string: APIEndpoints.modifyMessage(id: id))!
        var request = try await authenticatedRequest(url: url)
        request.httpMethod = "POST"
        
        let body = ModifyMessageRequest(addLabelIds: addLabelIds, removeLabelIds: removeLabelIds)
        request.httpBody = try JSONEncoder().encode(body)
        
        let (data, _) = try await session.data(for: request)
        return try JSONDecoder().decode(GmailMessage.self, from: data)
    }
    
    nonisolated func batchModify(ids: [String], addLabelIds: [String]? = nil, removeLabelIds: [String]? = nil) async throws {
        let url = URL(string: APIEndpoints.batchModify())!
        var request = try await authenticatedRequest(url: url)
        request.httpMethod = "POST"

        let body = BatchModifyRequest(ids: ids, addLabelIds: addLabelIds, removeLabelIds: removeLabelIds)
        request.httpBody = try JSONEncoder().encode(body)

        let (_, _) = try await session.data(for: request)
    }

    nonisolated func archiveMessages(ids: [String]) async throws {
        // Archive by removing INBOX label
        try await batchModify(ids: ids, removeLabelIds: ["INBOX"])
    }
    
    nonisolated func listHistory(startHistoryId: String, pageToken: String? = nil) async throws -> HistoryResponse {
        var components = URLComponents(string: APIEndpoints.history())!
        components.queryItems = [
            URLQueryItem(name: "startHistoryId", value: startHistoryId)
        ]
        if let pageToken = pageToken {
            components.queryItems?.append(URLQueryItem(name: "pageToken", value: pageToken))
        }
        
        let request = try await authenticatedRequest(url: components.url!)
        return try await performRequestWithRetry(request)
    }
    
    nonisolated func listSendAs() async throws -> [SendAs] {
        let url = URL(string: APIEndpoints.sendAs())!
        let request = try await authenticatedRequest(url: url)
        let (data, _) = try await session.data(for: request)
        let response = try JSONDecoder().decode(SendAsListResponse.self, from: data)
        return response.sendAs ?? []
    }
    
    nonisolated func getAttachment(messageId: String, attachmentId: String) async throws -> Data {
        let url = URL(string: APIEndpoints.attachment(messageId: messageId, attachmentId: attachmentId))!
        let request = try await authenticatedRequest(url: url)
        let (data, _) = try await session.data(for: request)
        
        struct AttachmentResponse: Codable {
            let size: Int
            let data: String
        }
        
        let response = try JSONDecoder().decode(AttachmentResponse.self, from: data)
        
        guard let attachmentData = Data(base64UrlEncoded: response.data) else {
            throw NSError(domain: "GmailAPI", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to decode attachment data"])
        }
        
        return attachmentData
    }
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