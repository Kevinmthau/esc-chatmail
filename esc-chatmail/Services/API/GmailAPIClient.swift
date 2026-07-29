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
        try await performRetryingRequest(
            request,
            maxRetries: maxRetries,
            behavior: GmailRetryPathBehavior(
                allowsRetransmission: allowsRetransmission,
                thrownAPIErrorsAbortImmediately: false,
                wrapsDecodingErrors: true,
                logContext: "Request"
            )
        ) { statusCode, data in
            if let statusCode {
                switch statusCode {
                case 403:
                    throw self.classify403(from: data)

                case 404:
                    throw APIError.notFound(self.gmailErrorMessage(from: data) ?? "resource")

                case 400...499:
                    let errorMessage = self.gmailErrorMessage(from: data) ?? HTTPURLResponse.localizedString(forStatusCode: statusCode)
                    throw APIError.invalidData("Gmail API \(statusCode): \(errorMessage)")

                case 200...299 where data.isEmpty:
                    if let empty = EmptyResponse() as? T {
                        return empty
                    }

                case 200...299:
                    if let detail = self.gmailErrorDetail(from: data) {
                        throw APIError.invalidData("Gmail API error \(detail.code): \(detail.message)")
                    }

                default:
                    break
                }
            }

            // Record success to help recover from rate limiting
            await self.rateLimitTracker.recordSuccess()
            return try JSONDecoder().decode(T.self, from: data)
        }
    }

    // MARK: - Shared Retry Engine

    /// Per-path parameterization of `performRetryingRequest`. The message and
    /// history paths share one engine; these knobs hold their intentional
    /// divergences (everything else — attempt accounting, the once-only 401
    /// refresh grant, 429 pacing with capped Retry-After, 5xx backoff, and the
    /// time-budget circuit breaker — is engine-owned and identical).
    struct GmailRetryPathBehavior {
        /// Non-idempotent sends set false: the request is never resent after
        /// an ambiguous failure (5xx, timeout, dropped connection).
        var allowsRetransmission = true
        /// History aborts immediately on any APIError thrown by status
        /// handling; the message path lets `RetryStrategy.shouldRetry`
        /// mediate (so a breaker-tripped `rateLimited` keeps consuming
        /// attempts with synthetic backoff instead of aborting outright).
        var thrownAPIErrorsAbortImmediately = false
        /// The message path wraps DecodingError into APIError.decodingError
        /// when aborting; history propagates it raw.
        var wrapsDecodingErrors = false
        /// Prefix for retry-failure log lines ("Request" / "History request").
        var logContext = "Request"
    }

    /// One retry engine for both Gmail request paths.
    ///
    /// `handleStatus` receives every status the engine does not own (anything
    /// other than 429/401/5xx, plus `nil` for non-HTTP responses) and either
    /// returns the decoded value or throws the path's error mapping — this is
    /// where the intentional 404 divergence lives (`notFound` for messages,
    /// `historyIdExpired` for history).
    nonisolated func performRetryingRequest<T>(
        _ request: URLRequest,
        maxRetries: Int? = nil,
        behavior: GmailRetryPathBehavior,
        handleStatus: (Int?, Data) async throws -> T
    ) async throws -> T {
        let retries = maxRetries ?? retryStrategy.maxRetries
        let startTime = Date()
        var lastError: Error?
        var retryDelay = retryStrategy.initialDelay
        var currentRequest = request
        var hasAttemptedTokenRefresh = false

        // 1-based attempt counter, incremented at the TOP of the loop body so
        // every `continue` (429/5xx/401 paths) advances it. `allowedAttempts`
        // grows by one on a successful 401 token refresh: the refresh consumed
        // that attempt's request slot, and without the grant a refresh on the
        // final attempt would exit the loop as `URLError(.unknown)` — a
        // non-retriable error — even though the new token was never tried.
        var attempt = 0
        var allowedAttempts = retries

        while attempt < allowedAttempts {
            attempt += 1

            // Circuit breaker: check if we've exceeded max total retry time
            let elapsedTime = Date().timeIntervalSince(startTime)
            if elapsedTime >= NetworkConfig.maxTotalRetryTime {
                Log.warning("Circuit breaker triggered: exceeded max total retry time (\(NetworkConfig.maxTotalRetryTime)s)", category: .api)
                throw lastError ?? APIError.timeout
            }

            do {
                let (data, response) = try await session.data(for: currentRequest)
                guard let httpResponse = response as? HTTPURLResponse else {
                    return try await handleStatus(nil, data)
                }

                switch httpResponse.statusCode {
                case 429:
                    // Respect Retry-After header if present, but cap it.
                    // The (capped) header value rides on the thrown error
                    // so outer retry owners can honor server pacing.
                    let headerRetryAfter: TimeInterval? = httpResponse
                        .value(forHTTPHeaderField: "Retry-After")
                        .flatMap(TimeInterval.init)
                        .map { min($0, NetworkConfig.maxRetryAfterSeconds) }

                    let delay: TimeInterval
                    if let headerRetryAfter {
                        Log.warning("Rate limited, Retry-After requests \(headerRetryAfter)s (capped)", category: .api)
                        delay = headerRetryAfter
                    } else {
                        delay = retryDelay * 2
                        Log.warning("Rate limited, using exponential backoff: \(delay) seconds", category: .api)
                    }

                    // Breaker/budget checks precede recordBackoff so only
                    // delays actually slept are recorded — otherwise N
                    // concurrent 429s at maxRetries 1 would trip the 120s
                    // breaker without anyone waiting at all.
                    if await rateLimitTracker.shouldAbort() {
                        Log.warning("Circuit breaker: excessive cumulative rate limiting, aborting", category: .api)
                        throw APIError.rateLimited(retryAfter: headerRetryAfter)
                    }

                    // Check if delay would exceed remaining time budget
                    let remainingTime = NetworkConfig.maxTotalRetryTime - Date().timeIntervalSince(startTime)
                    if delay > remainingTime {
                        Log.warning("Circuit breaker: delay (\(delay)s) exceeds remaining time budget (\(remainingTime)s)", category: .api)
                        throw APIError.rateLimited(retryAfter: headerRetryAfter)
                    }

                    if attempt >= allowedAttempts {
                        throw APIError.rateLimited(retryAfter: headerRetryAfter)
                    }

                    await rateLimitTracker.recordBackoff(delay)
                    try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                    retryDelay = min(delay * 2, retryStrategy.maxDelay)
                    continue

                case 500...599:
                    Log.warning("Server error \(httpResponse.statusCode), attempt \(attempt)/\(allowedAttempts)", category: .api)
                    // A 5xx is ambiguous for non-idempotent requests: the server may
                    // have processed the request before failing. Never resend.
                    if behavior.allowsRetransmission, attempt < allowedAttempts {
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
                    throw APIError.serverError(httpResponse.statusCode)

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
                            // The refresh consumed this attempt; grant one more so
                            // the refreshed token always gets its request (bounded:
                            // hasAttemptedTokenRefresh makes this once-only).
                            allowedAttempts += 1
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

                default:
                    return try await handleStatus(httpResponse.statusCode, data)
                }

            } catch {
                if behavior.thrownAPIErrorsAbortImmediately, let apiError = error as? APIError {
                    throw apiError
                }

                lastError = error
                Log.error("\(behavior.logContext) failed (attempt \(attempt)/\(allowedAttempts)): \(Log.redact(error: error))", category: .api)

                // Non-idempotent requests may only be resent when the error proves the
                // request never reached the server (DNS/connect/TLS failures). Timeouts
                // and dropped connections are ambiguous — the send may have gone through.
                let blocksRetransmission = !behavior.allowsRetransmission
                    && !ConnectionErrorDetector.isPreTransmissionError(error)
                if blocksRetransmission || !retryStrategy.shouldRetry(error: error, attempt: attempt - 1) {
                    if behavior.wrapsDecodingErrors, error is DecodingError {
                        throw APIError.decodingError(error)
                    }
                    throw error
                }

                if attempt < allowedAttempts {
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

    /// Gmail uses 403 for both retryable rate limiting and terminal
    /// policy/scope failures; the nested `errors[].reason` disambiguates.
    /// See https://developers.google.com/workspace/gmail/api/guides/handle-errors
    nonisolated func classify403(from data: Data) -> APIError {
        let message = gmailErrorMessage(from: data) ?? "Missing required OAuth permissions"
        switch gmailErrorDetail(from: data)?.primaryReason {
        case "rateLimitExceeded", "userRateLimitExceeded":
            return .rateLimited(retryAfter: nil)
        case "dailyLimitExceeded", "quotaExceeded":
            return .quotaExhausted(message)
        default:
            // Policy/scope failures (insufficientPermissions, domainPolicy,
            // accessNotConfigured, …) and reason-less bodies stay terminal.
            return .invalidData("Gmail API 403: \(message)")
        }
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
