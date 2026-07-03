import Foundation

// MARK: - Token Refresh Implementation
extension TokenManager {
    func performTokenRefresh() async throws -> String {
        var lastError: Error?

        for attempt in 0..<maxRetryAttempts {
            do {
                // Use exponential backoff for retries
                if attempt > 0 {
                    let delay = await refreshBackoff.nextDelay()
                    try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                }

                // Attempt to refresh using the token refresher
                let tokens = try await tokenRefresher.refreshTokens()

                // Save the new tokens
                try saveTokens(
                    access: tokens.accessToken,
                    refresh: tokens.refreshToken,
                    expirationDate: tokens.expirationDate
                )

                // Ensure memory cache is updated before returning so concurrent
                // callers to getCurrentToken() see the fresh token immediately
                await self.updateMemoryCache(
                    accessToken: tokens.accessToken,
                    expirationDate: tokens.expirationDate
                )

                await refreshBackoff.reset()
                return tokens.accessToken

            } catch let error {
                lastError = error

                // Check if error is retryable
                if !isRetryableError(error) {
                    // Wrap invalid_grant errors specifically so callers can detect revoked credentials
                    let thrownError: Error = isInvalidGrantError(error) ? TokenManagerError.invalidCredentials : error
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
            case .noValidToken, .invalidCredentials, .tokenExpired:
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
