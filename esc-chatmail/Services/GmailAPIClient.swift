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
final class GmailAPIClient: GmailAPIClientProtocol, @unchecked Sendable {
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

    /// Performs a request with automatic retry handling and circuit breaker.
    ///
    /// The circuit breaker prevents indefinite waiting by:
    /// - Capping individual Retry-After delays to `NetworkConfig.maxRetryAfterSeconds`
    /// - Aborting if total elapsed time exceeds `NetworkConfig.maxTotalRetryTime`
    nonisolated func performRequestWithRetry<T: Decodable>(_ request: URLRequest, maxRetries: Int? = nil) async throws -> T {
        let retries = maxRetries ?? retryStrategy.maxRetries
        let startTime = Date()
        var lastError: Error?
        var retryDelay = retryStrategy.initialDelay

        for attempt in 0..<retries {
            // Circuit breaker: check if we've exceeded max total retry time
            let elapsedTime = Date().timeIntervalSince(startTime)
            if elapsedTime >= NetworkConfig.maxTotalRetryTime {
                Log.warning("Circuit breaker triggered: exceeded max total retry time (\(NetworkConfig.maxTotalRetryTime)s)", category: .api)
                throw lastError ?? APIError.timeout
            }

            do {
                let (data, response) = try await session.data(for: request)

                if let httpResponse = response as? HTTPURLResponse {
                    switch httpResponse.statusCode {
                    case 429:
                        // Respect Retry-After header if present, but cap it
                        var delay: TimeInterval
                        if let retryAfter = httpResponse.value(forHTTPHeaderField: "Retry-After"),
                           let retryAfterSeconds = TimeInterval(retryAfter) {
                            delay = min(retryAfterSeconds, NetworkConfig.maxRetryAfterSeconds)
                            if retryAfterSeconds > NetworkConfig.maxRetryAfterSeconds {
                                Log.warning("Rate limited, Retry-After (\(retryAfterSeconds)s) capped to \(delay)s", category: .api)
                            } else {
                                Log.warning("Rate limited, Retry-After header requests \(delay) seconds", category: .api)
                            }
                        } else {
                            delay = retryDelay * 2
                            Log.warning("Rate limited, using exponential backoff: \(delay) seconds", category: .api)
                        }

                        // Check if delay would exceed remaining time budget
                        let remainingTime = NetworkConfig.maxTotalRetryTime - Date().timeIntervalSince(startTime)
                        if delay > remainingTime {
                            Log.warning("Circuit breaker: delay (\(delay)s) exceeds remaining time budget (\(remainingTime)s)", category: .api)
                            throw APIError.rateLimited
                        }

                        try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                        retryDelay = min(delay * 2, retryStrategy.maxDelay)
                        continue

                    case 500...599:
                        Log.warning("Server error \(httpResponse.statusCode), attempt \(attempt + 1)/\(retries)", category: .api)
                        if attempt < retries - 1 {
                            // Check time budget before sleeping
                            let remainingTime = NetworkConfig.maxTotalRetryTime - Date().timeIntervalSince(startTime)
                            if retryDelay > remainingTime {
                                Log.warning("Circuit breaker: retry delay exceeds remaining time budget", category: .api)
                                throw APIError.serverError(httpResponse.statusCode)
                            }
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
                    // Check time budget before sleeping
                    let remainingTime = NetworkConfig.maxTotalRetryTime - Date().timeIntervalSince(startTime)
                    if retryDelay > remainingTime {
                        Log.warning("Circuit breaker: retry delay exceeds remaining time budget", category: .api)
                        throw lastError ?? URLError(.timedOut)
                    }
                    Log.info("Retrying in \(retryDelay) seconds...", category: .api)
                    try await Task.sleep(nanoseconds: UInt64(retryDelay * 1_000_000_000))
                    retryDelay = min(retryDelay * 2, retryStrategy.maxDelay)
                }
            }
        }

        throw lastError ?? URLError(.unknown)
    }
}
