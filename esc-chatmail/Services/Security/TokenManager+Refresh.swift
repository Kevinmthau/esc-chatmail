import Foundation

// MARK: - Token Refresh Implementation
extension TokenManager {
    /// `rejectedAccessToken` is set for the 401 path's refresh
    /// (`refreshToken(rejecting:)`): where GoogleSignIn's own refresh hands
    /// that token back, which it does while the token's device-clock expiry
    /// looks distant (a clock set back), the refresher is asked again with
    /// `forceRefreshTokens()`, and only that answer is saved. The comparison
    /// is here and not in `GoogleTokenRefresher` so that it runs in tests,
    /// which replace the refresher.
    func performTokenRefresh(
        ifCacheEpochMatches epochAtStart: UInt64,
        rejecting rejectedAccessToken: String? = nil
    ) async throws -> String {
        // A refresh for a rejected token that starts after another one has
        // already replaced it (its caller read the cache before that save and
        // reached the coordinator after its entry was cleared) asks Google
        // nothing. Only within its own generation: a retired one falls
        // through to the loop's guard and is cancelled.
        if let rejectedAccessToken,
           let replacement = cachedReplacement(
               for: rejectedAccessToken,
               ifCacheEpochMatches: epochAtStart
           ) {
            return replacement
        }

        var lastError: Error?
        var retryBackoff = ExponentialBackoff()

        for attempt in 0..<maxRetryAttempts {
            guard cacheEpochMatches(epochAtStart) else {
                throw CancellationError()
            }

            do {
                // Use exponential backoff for retries
                if attempt > 0 {
                    let delay = retryBackoff.nextDelay()
                    try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                    guard cacheEpochMatches(epochAtStart) else {
                        throw CancellationError()
                    }
                }

                // Attempt to refresh using the token refresher
                var tokens = try await tokenRefresher.refreshTokens()
                if let rejectedAccessToken, tokens.accessToken == rejectedAccessToken {
                    guard cacheEpochMatches(epochAtStart) else {
                        throw CancellationError()
                    }
                    Log.info("GoogleSignIn returned the token Gmail rejected; forcing a token refresh", category: .auth)
                    // Its errors take the same path as the plain refresh's:
                    // an invalid_grant here is `invalidCredentials` and a
                    // published revocation, a transient one is retried.
                    tokens = try await tokenRefresher.forceRefreshTokens()
                }

                // Save the new tokens (drops silently if sign-out raced the
                // refresh). The cache is populated synchronously inside
                // saveTokens, so concurrent getCurrentToken callers see the
                // fresh token immediately without a separate publish step.
                let saved = try saveTokens(
                    access: tokens.accessToken,
                    refresh: tokens.refreshToken,
                    expirationDate: tokens.expirationDate,
                    ifCacheEpochMatches: epochAtStart
                )
                if !saved {
                    Log.info("Token refresh completed for a retired session; discarding tokens", category: .auth)
                    throw CancellationError()
                }

                return tokens.accessToken

            } catch let error {
                guard cacheEpochMatches(epochAtStart) else {
                    throw CancellationError()
                }
                if error is CancellationError {
                    throw error
                }
                lastError = error

                // Check if error is retryable
                if !isRetryableError(error) {
                    // Wrap every invalid-credential verdict consistently and
                    // surface reauthentication without deleting the isolated
                    // mailbox or its durable pending actions.
                    let credentialsWereRevoked: Bool
                    if let tokenError = error as? TokenManagerError {
                        switch tokenError {
                        case .invalidCredentials:
                            credentialsWereRevoked = true
                        case .refreshFailed(let underlyingError):
                            credentialsWereRevoked = isInvalidGrantError(underlyingError)
                        default:
                            credentialsWereRevoked = false
                        }
                    } else {
                        credentialsWereRevoked = isInvalidGrantError(error)
                    }
                    let thrownError: Error = credentialsWereRevoked
                        ? TokenManagerError.invalidCredentials
                        : error
                    if credentialsWereRevoked {
                        await publishCredentialRevocation(
                            ifCacheEpochMatches: epochAtStart
                        )
                    }
                    await MainActor.run {
                        self.lastRefreshError = thrownError
                    }
                    throw thrownError
                }

                // Log retry attempt
                Log.warning("Token refresh attempt \(attempt + 1) failed: \(error)", category: .auth)
            }
        }

        // All retries failed
        guard cacheEpochMatches(epochAtStart) else {
            throw CancellationError()
        }
        let finalError = lastError ?? TokenManagerError.refreshFailed(NSError(domain: "TokenManager", code: -1))
        await MainActor.run {
            self.lastRefreshError = finalError
        }
        throw finalError
    }

    func loadTokenInfo() throws -> TokenInfo {
        return try keychainService.loadCodable(TokenInfo.self, for: KeychainService.Key.googleAccessToken.rawValue)
    }

    func isRetryableError(_ error: Error) -> Bool {
        // Determine if the error is retryable
        if let tokenError = error as? TokenManagerError {
            switch tokenError {
            case .networkUnavailable, .rateLimitExceeded:
                return true
            case .noValidToken, .invalidCredentials, .tokenExpired, .refreshedIDTokenRefused:
                return false
            case .refreshFailed(let underlying):
                // Check for invalid_grant error - this means the refresh token is revoked
                // and retry won't help; user needs to re-authenticate
                if isInvalidGrantError(underlying) {
                    Log.warning("Refresh token revoked (invalid_grant) - user must re-authenticate", category: .auth)
                    return false
                }
                return true // Other refresh failures could be transient
            }
        }

        // Check for invalid_grant in the raw error
        if isInvalidGrantError(error) {
            return false
        }

        // Check for network errors
        let nsError = error as NSError
        let networkErrorCodes = [
            NSURLErrorNotConnectedToInternet,
            NSURLErrorNetworkConnectionLost,
            NSURLErrorTimedOut,
            NSURLErrorCannotConnectToHost
        ]

        return networkErrorCodes.contains(nsError.code)
    }

    /// Checks if an error indicates an invalid_grant OAuth error.
    /// This occurs when:
    /// - User has revoked app access
    /// - Refresh token has expired (rare, but possible after 6 months of inactivity)
    /// - Account password changed and security settings require re-auth
    /// - Token was issued to a deleted Google account
    ///
    /// Note: This check is locale-independent - it examines userInfo directly
    /// rather than relying on localizedDescription which varies by locale.
    private func isInvalidGrantError(_ error: Error?) -> Bool {
        guard let error = error else { return false }

        let nsError = error as NSError

        // AppAuth reports token-endpoint OAuth failures in this canonical
        // domain/code shape, with the response fields nested in userInfo.
        if nsError.domain == "org.openid.appauth.oauth_token",
           nsError.code == -10 {
            return true
        }

        if let response = nsError.userInfo["OIDOAuthErrorResponseErrorKey"] as? [String: Any],
           (response["error"] as? String) == "invalid_grant" {
            return true
        }

        // Check userInfo directly for OAuth error code (locale-independent)
        // This is the most reliable way to detect invalid_grant
        if nsError.code == 400 {
            // Check for "error" key in userInfo (common OAuth error format)
            if let oauthError = nsError.userInfo["error"] as? String,
               oauthError == "invalid_grant" {
                return true
            }

            // Check for JSON response body in userInfo["data"]
            if let data = nsError.userInfo["data"] as? Data,
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               (json["error"] as? String) == "invalid_grant" {
                return true
            }

            // Check for NSLocalizedFailure with raw error (not localized string)
            if let failure = nsError.userInfo[NSLocalizedFailureReasonErrorKey] as? String,
               failure.contains("invalid_grant") {
                return true
            }
        }

        // Check underlying error recursively
        if let underlyingError = nsError.userInfo[NSUnderlyingErrorKey] as? NSError {
            return isInvalidGrantError(underlyingError)
        }

        return false
    }
}
