import Foundation

// MARK: - History API

extension GmailAPIClient {

    /// Lists history changes since a given history ID.
    /// Uses retry logic with circuit breaker, converting 404 to historyIdExpired.
    nonisolated func listHistory(startHistoryId: String, pageToken: String? = nil) async throws -> HistoryResponse {
        var queryItems = [URLQueryItem(name: "startHistoryId", value: startHistoryId)]
        if let pageToken = pageToken {
            queryItems.append(URLQueryItem(name: "pageToken", value: pageToken))
        }
        let url = try buildURL(endpoint: APIEndpoints.history(), queryItems: queryItems)
        let request = try await authenticatedRequest(url: url)

        return try await performHistoryRequestWithRetry(request)
    }

    /// Performs a history API request with retry handling and special 404 conversion.
    /// Uses the same circuit breaker and retry logic as performRequestWithRetry,
    /// but converts 404 responses to historyIdExpired errors.
    nonisolated func performHistoryRequestWithRetry(_ request: URLRequest) async throws -> HistoryResponse {
        let retries = retryStrategy.maxRetries
        let startTime = Date()
        var lastError: Error?
        var retryDelay = retryStrategy.initialDelay
        var currentRequest = request
        var hasAttemptedTokenRefresh = false

        // Same attempt accounting as performRequestWithRetry: 1-based counter
        // incremented at the top so every `continue` advances it, and one
        // extra attempt granted after a successful 401 token refresh (bounded
        // by hasAttemptedTokenRefresh) so the refreshed token is always tried.
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
                    throw APIError.networkError(URLError(.badServerResponse))
                }

                switch httpResponse.statusCode {
                case 200:
                    await rateLimitTracker.recordSuccess()
                    return try JSONDecoder().decode(HistoryResponse.self, from: data)

                case 404:
                    // Gmail returns 404 when historyId is expired or invalid - don't retry
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

                    // Final-attempt guard (previously missing here): without it
                    // the loop slept the full Retry-After and then fell out as
                    // URLError(.unknown) instead of rateLimited.
                    if attempt >= allowedAttempts {
                        throw APIError.rateLimited
                    }

                    try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                    retryDelay = min(delay * 2, retryStrategy.maxDelay)
                    continue

                case 401:
                    // Attempt reactive token refresh on 401
                    if !hasAttemptedTokenRefresh {
                        hasAttemptedTokenRefresh = true
                        Log.info("Received 401, attempting token refresh", category: .api)
                        do {
                            _ = try await tokenManager.refreshToken()
                            let newToken = try await tokenManager.getCurrentToken()
                            currentRequest.setValue("Bearer \(newToken)", forHTTPHeaderField: "Authorization")
                            // The refresh consumed this attempt; grant one more so
                            // the refreshed token always gets its request.
                            allowedAttempts += 1
                            continue
                        } catch TokenManagerError.invalidCredentials {
                            // Mirrors performRequestWithRetry: a revoked refresh
                            // token must abort (credentialsRevoked → abortNoRetry),
                            // not loop through tokenRefreshAndRetry.
                            Log.error("Refresh token revoked, user must re-authenticate", category: .api)
                            throw APIError.credentialsRevoked
                        } catch {
                            Log.error("Token refresh failed during 401 recovery: \(error.localizedDescription)", category: .api)
                            throw APIError.authenticationError
                        }
                    }
                    throw APIError.authenticationError

                case 500...599:
                    Log.warning("Server error \(httpResponse.statusCode), attempt \(attempt)/\(allowedAttempts)", category: .api)
                    if attempt < allowedAttempts {
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

                case 400...499:
                    // Remaining client errors (403 quota/scope, 400 bad request …)
                    // are non-retriable; mirrors performRequestWithRetry. Placed
                    // after the specific 404/429/401 cases so their retry and
                    // conversion behavior is untouched.
                    let errorMessage = gmailErrorMessage(from: data)
                        ?? HTTPURLResponse.localizedString(forStatusCode: httpResponse.statusCode)
                    throw APIError.invalidData("Gmail API \(httpResponse.statusCode): \(errorMessage)")

                default:
                    throw APIError.serverError(httpResponse.statusCode)
                }

            } catch let error as APIError {
                // Don't retry API errors like historyIdExpired or authenticationError
                throw error
            } catch {
                lastError = error
                Log.error("History request failed (attempt \(attempt)/\(allowedAttempts)): \(error.localizedDescription)", category: .api)

                if !retryStrategy.shouldRetry(error: error, attempt: attempt - 1) {
                    throw error
                }

                if attempt < allowedAttempts {
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
