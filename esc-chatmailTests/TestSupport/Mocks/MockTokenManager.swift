import Foundation
@testable import esc_chatmail

/// Mock implementation of TokenManagerProtocol for testing.
/// Allows controlling token behavior without actual authentication.
final class MockTokenManager: TokenManagerProtocol {

    /// The token to return from getCurrentToken()
    var currentToken: String = "mock-access-token-12345"

    /// The token to return after refresh
    var refreshedToken: String = "mock-refreshed-token-67890"

    /// Whether the mock should simulate being authenticated
    var isAuthenticatedValue: Bool = true

    /// Error to throw on getCurrentToken() (resets after throwing)
    var getTokenError: Error?

    /// Error to throw on refreshToken() (resets after throwing)
    var refreshError: Error?

    /// Error to throw on saveTokens() (resets after throwing)
    var saveError: Error?

    /// Error to throw on clearTokens() (resets after throwing)
    var clearError: Error?

    /// Tracks method calls for verification
    private(set) var getCurrentTokenCallCount = 0
    private(set) var refreshTokenCallCount = 0
    private(set) var saveTokensCallCount = 0
    private(set) var clearTokensCallCount = 0
    private(set) var isAuthenticatedCallCount = 0

    /// Last saved tokens for inspection
    private(set) var lastSavedAccessToken: String?
    private(set) var lastSavedRefreshToken: String?
    private(set) var lastSavedExpirationDate: Date?

    /// Delay to simulate network latency (in seconds)
    var artificialDelay: TimeInterval = 0

    /// Resets all state
    func reset() {
        currentToken = "mock-access-token-12345"
        refreshedToken = "mock-refreshed-token-67890"
        isAuthenticatedValue = true
        getTokenError = nil
        refreshError = nil
        saveError = nil
        clearError = nil
        getCurrentTokenCallCount = 0
        refreshTokenCallCount = 0
        saveTokensCallCount = 0
        clearTokensCallCount = 0
        isAuthenticatedCallCount = 0
        lastSavedAccessToken = nil
        lastSavedRefreshToken = nil
        lastSavedExpirationDate = nil
        artificialDelay = 0
    }

    // MARK: - TokenManagerProtocol

    func getCurrentToken() async throws -> String {
        getCurrentTokenCallCount += 1

        if artificialDelay > 0 {
            try await Task.sleep(nanoseconds: UInt64(artificialDelay * 1_000_000_000))
        }

        if let error = getTokenError {
            getTokenError = nil
            throw error
        }

        return currentToken
    }

    func refreshToken() async throws -> String {
        refreshTokenCallCount += 1

        if artificialDelay > 0 {
            try await Task.sleep(nanoseconds: UInt64(artificialDelay * 1_000_000_000))
        }

        if let error = refreshError {
            refreshError = nil
            throw error
        }

        currentToken = refreshedToken
        return refreshedToken
    }

    func saveTokens(access: String, refresh: String?, expirationDate: Date) throws {
        saveTokensCallCount += 1

        if let error = saveError {
            saveError = nil
            throw error
        }

        lastSavedAccessToken = access
        lastSavedRefreshToken = refresh
        lastSavedExpirationDate = expirationDate
        currentToken = access
    }

    func clearTokens() throws {
        clearTokensCallCount += 1

        if let error = clearError {
            clearError = nil
            throw error
        }

        currentToken = ""
        lastSavedAccessToken = nil
        lastSavedRefreshToken = nil
        lastSavedExpirationDate = nil
        isAuthenticatedValue = false
    }

    func isAuthenticated() -> Bool {
        isAuthenticatedCallCount += 1
        return isAuthenticatedValue
    }
}

// MARK: - Test Helpers

extension MockTokenManager {
    /// Configures the mock to simulate an expired token that needs refresh
    func simulateExpiredToken() {
        getTokenError = TokenManagerError.tokenExpired
    }

    /// Configures the mock to simulate no valid token available
    func simulateNoToken() {
        isAuthenticatedValue = false
        getTokenError = TokenManagerError.noValidToken
    }

    /// Configures the mock to simulate a network error during refresh
    func simulateRefreshNetworkError() {
        refreshError = TokenManagerError.networkUnavailable
    }

    /// Configures the mock to simulate invalid credentials
    func simulateInvalidCredentials() {
        getTokenError = TokenManagerError.invalidCredentials
        refreshError = TokenManagerError.invalidCredentials
    }

    /// Configures the mock to simulate rate limiting
    func simulateRateLimited() {
        getTokenError = TokenManagerError.rateLimitExceeded
    }
}
