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
        configuration.timeoutIntervalForRequest = max(NetworkConfig.requestTimeout, 30.0)
        configuration.timeoutIntervalForResource = NetworkConfig.resourceTimeout
        configuration.waitsForConnectivity = true // Wait for network connectivity
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData

        self.session = URLSession(configuration: configuration)
    }

    /// Checks if an error is a connection-level error that should be retried
    private nonisolated func isConnectionError(_ error: Error) -> Bool {
        let nsError = error as NSError

        // POSIX errors (connection reset, broken pipe, etc.)
        if nsError.domain == NSPOSIXErrorDomain {
            // ECONNRESET (54), EPIPE (32), ENOTCONN (57), ENETDOWN (50), ENETRESET (52)
            return [32, 50, 52, 54, 57].contains(nsError.code)
        }

        // NSURLError connection-related codes
        if nsError.domain == NSURLErrorDomain {
            switch nsError.code {
            case NSURLErrorNetworkConnectionLost,      // -1005
                 NSURLErrorNotConnectedToInternet,     // -1009
                 NSURLErrorCannotConnectToHost,        // -1004
                 NSURLErrorTimedOut,                   // -1001
                 NSURLErrorSecureConnectionFailed,     // -1200
                 NSURLErrorCannotFindHost,             // -1003
                 NSURLErrorDNSLookupFailed,            // -1006
                 -1022,  // NSURLErrorAppTransportSecurityRequiresSecureConnection
                 -1017,  // NSURLErrorCannotParseResponse
                 -1011,  // NSURLErrorBadServerResponse
                 -997:   // Lost connection before completion
                return true
            default:
                return false
            }
        }

        // Check for QUIC-specific errors in the underlying error
        if let underlyingError = nsError.userInfo[NSUnderlyingErrorKey] as? NSError {
            return isConnectionError(underlyingError)
        }

        return false
    }

    private nonisolated func authenticatedRequest(url: URL) async throws -> URLRequest {
        // Validate URL before creating request
        guard isValidURL(url) else {
            throw APIError.invalidURL(url.absoluteString)
        }

        var request = URLRequest(url: url)

        // Disable HTTP/3 (QUIC) to avoid sec_framer_open_aesgcm and quic_conn errors
        // HTTP/2 is more stable and still provides multiplexing benefits
        if #available(iOS 14.5, *) {
            request.assumesHTTP3Capable = false
        }

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
                    } else if httpResponse.statusCode == 401 {
                        throw APIError.authenticationError
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
                let errorDesc = error.localizedDescription
                print("Request failed (attempt \(attempt + 1)/\(maxRetries)): \(errorDesc)")

                // Don't retry auth errors
                if let apiError = error as? APIError, case .authenticationError = apiError {
                    throw error
                }

                // Check for connection-level errors (includes QUIC/HTTP3 issues)
                if isConnectionError(error) {
                    if attempt < maxRetries - 1 {
                        print("Connection error detected, retrying in \(retryDelay) seconds...")
                        try await Task.sleep(nanoseconds: UInt64(retryDelay * 1_000_000_000))
                        retryDelay = min(retryDelay * 2, NetworkConfig.maxRetryDelay)
                        continue
                    }
                }

                // Check if it's a URL error
                if let urlError = error as? URLError {
                    switch urlError.code {
                    case .notConnectedToInternet, .networkConnectionLost, .timedOut,
                         .cannotFindHost, .dnsLookupFailed, .cannotConnectToHost,
                         .secureConnectionFailed:
                        if attempt < maxRetries - 1 {
                            print("Network error (\(urlError.code.rawValue)), retrying in \(retryDelay) seconds...")
                            try await Task.sleep(nanoseconds: UInt64(retryDelay * 1_000_000_000))
                            retryDelay = min(retryDelay * 2, NetworkConfig.maxRetryDelay)
                            continue
                        }
                    case .unsupportedURL:
                        // Don't retry unsupported URLs
                        print("Unsupported URL error - not retrying")
                        throw APIError.invalidURL(request.url?.absoluteString ?? "unknown")
                    default:
                        // For other URL errors, check if it's connection-related
                        if attempt < maxRetries - 1 {
                            print("URL error (\(urlError.code.rawValue)), retrying...")
                            try await Task.sleep(nanoseconds: UInt64(retryDelay * 1_000_000_000))
                            retryDelay = min(retryDelay * 2, NetworkConfig.maxRetryDelay)
                            continue
                        }
                    }
                }

                // For decoding errors, don't retry
                if error is DecodingError {
                    throw APIError.decodingError(error)
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

// Note: API response types moved to GmailAPIModels.swift for better organization