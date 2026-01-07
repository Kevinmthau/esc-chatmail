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

                await refreshBackoff.reset()
                return tokens.accessToken

            } catch let error {
                lastError = error

                // Check if error is retryable
                if !isRetryableError(error) {
                    await MainActor.run {
                        self.lastRefreshError = error
                    }
                    throw error
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
            case .refreshFailed:
                return true // Could be transient
            }
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
}
