import Foundation

// MARK: - Gmail API Client

/// Client for Gmail API operations.
///
/// The client is split across multiple files for organization:
/// - `GmailAPIClient.swift` - Core infrastructure and shared helpers
/// - `GmailAPIClient+Messages.swift` - Message listing, fetching, and modification
/// - `GmailAPIClient+Labels.swift` - Profile, labels, and aliases
/// - `GmailAPIClient+History.swift` - History API with specialized error handling
/// - `GmailAPIClient+Attachments.swift` - Attachment downloading
class GmailAPIClient {
    @MainActor static let shared = GmailAPIClient()

    let session: URLSession
    let tokenManager: TokenManagerProtocol
    let retryStrategy: RetryStrategy

    // MARK: - Initialization

    /// Production initializer - uses shared TokenManager.
    @MainActor private init() {
        self.tokenManager = TokenManager.shared
        self.retryStrategy = NetworkRetryStrategy()
        self.session = Self.createSession()
    }

    /// Testable initializer - accepts custom dependencies.
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

    // MARK: - Request Helpers

    /// Creates an authenticated request with the current access token.
    nonisolated func authenticatedRequest(url: URL) async throws -> URLRequest {
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

    /// Validates a URL for API requests.
    nonisolated func isValidURL(_ url: URL) -> Bool {
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

    /// Performs a request with automatic retry handling.
    nonisolated func performRequestWithRetry<T: Decodable>(_ request: URLRequest, maxRetries: Int? = nil) async throws -> T {
        let retries = maxRetries ?? retryStrategy.maxRetries
        var lastError: Error?
        var retryDelay = retryStrategy.initialDelay

        for attempt in 0..<retries {
            do {
                let (data, response) = try await session.data(for: request)

                if let httpResponse = response as? HTTPURLResponse {
                    switch httpResponse.statusCode {
                    case 429:
                        // Respect Retry-After header if present, otherwise use exponential backoff
                        let delay: TimeInterval
                        if let retryAfter = httpResponse.value(forHTTPHeaderField: "Retry-After"),
                           let retryAfterSeconds = TimeInterval(retryAfter) {
                            delay = retryAfterSeconds
                            Log.warning("Rate limited, Retry-After header requests \(delay) seconds", category: .api)
                        } else {
                            delay = retryDelay * 2
                            Log.warning("Rate limited, using exponential backoff: \(delay) seconds", category: .api)
                        }
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
}
