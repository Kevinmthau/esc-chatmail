import Foundation

// MARK: - Rate Limit Tracker

/// Tracks cumulative rate limit backoff time to prevent API exhaustion.
/// If we spend too much time in rate-limited backoff, we should stop making requests
/// temporarily rather than continuing to hammer the API.
actor RateLimitTracker {
    private var cumulativeBackoffTime: TimeInterval = 0
    private var windowStartTime: Date = Date()

    /// Maximum cumulative backoff time allowed in the window before circuit breaking
    private let maxCumulativeBackoff: TimeInterval = 120 // 2 minutes

    /// Time window for tracking cumulative backoff
    private let windowDuration: TimeInterval = 300 // 5 minutes

    /// Records time spent in rate limit backoff
    func recordBackoff(_ duration: TimeInterval) {
        resetWindowIfNeeded()
        cumulativeBackoffTime += duration
    }

    /// Returns true if we should abort due to excessive rate limiting
    func shouldAbort() -> Bool {
        resetWindowIfNeeded()
        return cumulativeBackoffTime >= maxCumulativeBackoff
    }

    /// Resets tracking after successful request
    func recordSuccess() {
        // Mitigation, not a fix: this credit-per-success accounting is
        // structurally wrong for a concurrent client — credit scales with
        // request concurrency while debit doesn't, and a success is causally
        // unrelated to 429 recovery. At the previous 30s credit, 4 interleaved
        // successes (out of 15 concurrent requests) wiped a fully tripped
        // 120s breaker. 2s keeps recovery possible on genuinely healthy
        // traffic without letting one concurrent batch erase the breaker.
        // A structural rewrite (time-decay/leaky bucket) is tracked as
        // deferred work in the performance plan (C4).
        cumulativeBackoffTime = max(0, cumulativeBackoffTime - 2)
    }

    /// Returns current cumulative backoff for monitoring
    var currentCumulativeBackoff: TimeInterval {
        cumulativeBackoffTime
    }

    private func resetWindowIfNeeded() {
        let now = Date()
        if now.timeIntervalSince(windowStartTime) >= windowDuration {
            windowStartTime = now
            cumulativeBackoffTime = 0
        }
    }
}

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
    @MainActor static let shared = GmailAPIClient(tokenManager: TokenManager.shared)

    let session: URLSession
    let tokenManager: TokenManagerProtocol
    let retryStrategy: RetryStrategy

    /// Tracks cumulative rate limit backoff time to prevent API exhaustion
    let rateLimitTracker = RateLimitTracker()

    // MARK: - Initialization

    /// Initializer with injectable dependencies.
    init(
        tokenManager: TokenManagerProtocol,
        retryStrategy: RetryStrategy = NetworkRetryStrategy(),
        session: URLSession? = nil
    ) {
        self.tokenManager = tokenManager
        self.retryStrategy = retryStrategy
        self.session = session ?? Self.createSession()
    }

    private static func createSession() -> URLSession {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = max(NetworkConfig.requestTimeout, 30.0)
        configuration.timeoutIntervalForResource = NetworkConfig.resourceTimeout
        configuration.waitsForConnectivity = true
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration)
    }

    // MARK: - URL Building

    /// Builds a URL from an endpoint string with optional query parameters.
    /// Uses URLComponents to ensure proper escaping of special characters.
    /// - Parameters:
    ///   - endpoint: The API endpoint URL string
    ///   - queryItems: Optional array of query parameters
    /// - Returns: The constructed URL
    /// - Throws: APIError.invalidURL if the URL cannot be constructed
    nonisolated func buildURL(endpoint: String, queryItems: [URLQueryItem]? = nil) throws -> URL {
        guard var components = URLComponents(string: endpoint) else {
            throw APIError.invalidURL(endpoint)
        }
        if let queryItems = queryItems, !queryItems.isEmpty {
            components.queryItems = queryItems
        }
        guard let url = components.url else {
            throw APIError.invalidURL(endpoint)
        }
        return url
    }

    // MARK: - Request Helpers

    /// Performs a simple GET request to an endpoint with optional query parameters.
    /// Consolidates the common pattern: buildURL → authenticatedRequest → performRequestWithRetry
    nonisolated func performGET<T: Decodable>(
        endpoint: String,
        queryItems: [URLQueryItem]? = nil
    ) async throws -> T {
        let url = try buildURL(endpoint: endpoint, queryItems: queryItems)
        let request = try await authenticatedRequest(url: url)
        return try await performRequestWithRetry(request)
    }

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
    ///
    /// Set `allowsRetransmission` to false for non-idempotent requests (messages.send):
    /// the request is never resent after an ambiguous failure (5xx, timeout, dropped
    /// connection), because the server may have already processed it. Retries are still
    /// performed when the failure proves the request was rejected or never delivered
    /// (401 after token refresh, 429, DNS/connect failures).
    nonisolated func performRequestWithRetry<T: Decodable>(
        _ request: URLRequest,
        maxRetries: Int? = nil,
        allowsRetransmission: Bool = true
    ) async throws -> T {
        let retries = maxRetries ?? retryStrategy.maxRetries
        let startTime = Date()
        var lastError: Error?
        var retryDelay = retryStrategy.initialDelay
        var currentRequest = request
        var hasAttemptedTokenRefresh = false

        for attempt in 0..<retries {
            // Circuit breaker: check if we've exceeded max total retry time
            let elapsedTime = Date().timeIntervalSince(startTime)
            if elapsedTime >= NetworkConfig.maxTotalRetryTime {
                Log.warning("Circuit breaker triggered: exceeded max total retry time (\(NetworkConfig.maxTotalRetryTime)s)", category: .api)
                throw lastError ?? APIError.timeout
            }

            do {
                let (data, response) = try await session.data(for: currentRequest)

                if let httpResponse = response as? HTTPURLResponse {
                    let statusCode = httpResponse.statusCode
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

                        // Track cumulative backoff to prevent API exhaustion
                        await rateLimitTracker.recordBackoff(delay)
                        if await rateLimitTracker.shouldAbort() {
                            Log.warning("Circuit breaker: excessive cumulative rate limiting, aborting", category: .api)
                            throw APIError.rateLimited
                        }

                        // Check if delay would exceed remaining time budget
                        let remainingTime = NetworkConfig.maxTotalRetryTime - Date().timeIntervalSince(startTime)
                        if delay > remainingTime {
                            Log.warning("Circuit breaker: delay (\(delay)s) exceeds remaining time budget (\(remainingTime)s)", category: .api)
                            throw APIError.rateLimited
                        }

                        if attempt >= retries - 1 {
                            throw APIError.rateLimited
                        }

                        try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                        retryDelay = min(delay * 2, retryStrategy.maxDelay)
                        continue

                    case 500...599:
                        Log.warning("Server error \(httpResponse.statusCode), attempt \(attempt + 1)/\(retries)", category: .api)
                        // A 5xx is ambiguous for non-idempotent requests: the server may
                        // have processed the request before failing. Never resend.
                        if allowsRetransmission, attempt < retries - 1 {
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
                        throw APIError.serverError(statusCode)

                    case 401:
                        // Attempt reactive token refresh on 401
                        // Only retry once to avoid infinite loops if refresh also fails
                        if !hasAttemptedTokenRefresh {
                            hasAttemptedTokenRefresh = true
                            Log.info("Received 401, attempting token refresh", category: .api)
                            do {
                                _ = try await tokenManager.refreshToken()
                                // Update request with refreshed token
                                let newToken = try await tokenManager.getCurrentToken()
                                currentRequest.setValue("Bearer \(newToken)", forHTTPHeaderField: "Authorization")
                                // Retry with new token
                                continue
                            } catch TokenManagerError.invalidCredentials {
                                Log.error("Refresh token revoked, user must re-authenticate", category: .api)
                                throw APIError.credentialsRevoked
                            } catch {
                                Log.error("Token refresh failed during 401 recovery: \(error.localizedDescription)", category: .api)
                                throw APIError.authenticationError
                            }
                        }
                        throw APIError.authenticationError

                    case 403:
                        let errorMessage = gmailErrorMessage(from: data) ?? "Missing required OAuth permissions"
                        throw APIError.invalidData("Gmail API 403: \(errorMessage)")

                    case 404:
                        throw APIError.notFound(gmailErrorMessage(from: data) ?? "resource")

                    case 400...499:
                        let errorMessage = gmailErrorMessage(from: data) ?? HTTPURLResponse.localizedString(forStatusCode: statusCode)
                        throw APIError.invalidData("Gmail API \(statusCode): \(errorMessage)")

                    case 200...299 where data.isEmpty:
                        if let empty = EmptyResponse() as? T {
                            return empty
                        }

                    case 200...299:
                        if let detail = gmailErrorDetail(from: data) {
                            throw APIError.invalidData("Gmail API error \(detail.code): \(detail.message)")
                        }

                    default:
                        break
                    }
                }

                // Record success to help recover from rate limiting
                await rateLimitTracker.recordSuccess()
                return try JSONDecoder().decode(T.self, from: data)

            } catch {
                lastError = error
                Log.error("Request failed (attempt \(attempt + 1)/\(retries)): \(error.localizedDescription)", category: .api)

                // Non-idempotent requests may only be resent when the error proves the
                // request never reached the server (DNS/connect/TLS failures). Timeouts
                // and dropped connections are ambiguous — the send may have gone through.
                let blocksRetransmission = !allowsRetransmission
                    && !ConnectionErrorDetector.isPreTransmissionError(error)
                if blocksRetransmission || !retryStrategy.shouldRetry(error: error, attempt: attempt) {
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

    private nonisolated func gmailErrorDetail(from data: Data) -> GmailErrorResponse.GmailErrorDetail? {
        guard !data.isEmpty else { return nil }
        return (try? JSONDecoder().decode(GmailErrorResponse.self, from: data))?.error
    }

    nonisolated func gmailErrorMessage(from data: Data) -> String? {
        if let detail = gmailErrorDetail(from: data) {
            if let status = detail.status, !status.isEmpty {
                return "\(detail.message) (\(status))"
            }
            return detail.message
        }

        guard let body = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !body.isEmpty else {
            return nil
        }

        // Keep fallback bodies short to avoid log/UI spam.
        return String(body.prefix(300))
    }
}
