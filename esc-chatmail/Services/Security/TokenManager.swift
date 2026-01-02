import Foundation
import GoogleSignIn
import Combine

// MARK: - Token Manager Error

enum TokenManagerError: LocalizedError {
    case noValidToken
    case refreshFailed(Error)
    case networkUnavailable
    case rateLimitExceeded
    case invalidCredentials
    case tokenExpired

    var errorDescription: String? {
        switch self {
        case .noValidToken:
            return "No valid authentication token available"
        case .refreshFailed(let error):
            return "Failed to refresh token: \(error.localizedDescription)"
        case .networkUnavailable:
            return "Network connection unavailable"
        case .rateLimitExceeded:
            return "Rate limit exceeded. Please try again later"
        case .invalidCredentials:
            return "Invalid credentials. Please sign in again"
        case .tokenExpired:
            return "Authentication token has expired"
        }
    }

    var recoverySuggestion: String? {
        switch self {
        case .noValidToken, .invalidCredentials, .tokenExpired:
            return "Please sign in again to continue"
        case .refreshFailed:
            return "Check your internet connection and try again"
        case .networkUnavailable:
            return "Please check your internet connection"
        case .rateLimitExceeded:
            return "Wait a few minutes before trying again"
        }
    }
}

// MARK: - Token Info

struct TokenInfo: Codable {
    let accessToken: String
    let refreshToken: String?
    let expirationDate: Date
    let scope: String?

    var isExpired: Bool {
        Date() >= expirationDate
    }

    var isExpiringSoon: Bool {
        // Consider token expiring soon if less than 5 minutes remain
        Date().addingTimeInterval(300) >= expirationDate
    }
}

// MARK: - Token Manager Protocol

protocol TokenManagerProtocol {
    func getCurrentToken() async throws -> String
    func refreshToken() async throws -> String
    func saveTokens(access: String, refresh: String?, expirationDate: Date) throws
    func clearTokens() throws
    func isAuthenticated() -> Bool
}

// MARK: - Token Manager Implementation

/// TokenManager uses @unchecked Sendable because:
/// - All @Published properties are explicitly @MainActor isolated
/// - Internal coordination uses dedicated actors (TaskCoordinator, ExponentialBackoffActor)
/// - Nonisolated methods are carefully designed to not access mutable state directly
/// - ObservableObject pattern requires class semantics with Sendable conformance
final class TokenManager: ObservableObject, TokenManagerProtocol, @unchecked Sendable {
    @MainActor static let shared: TokenManager = TokenManager()

    @MainActor @Published private(set) var isRefreshing = false
    @MainActor @Published private(set) var lastRefreshError: Error?

    private let keychainService: KeychainServiceProtocol
    private let authSession: AuthSession
    private let refreshCoordinator = TaskCoordinator<String>()
    private let refreshBackoff = ExponentialBackoffActor()
    private let tokenRefresher: TokenRefresherProtocol

    // Token refresh configuration
    private let maxRetryAttempts = 3

    // MARK: - Initialization

    init(keychainService: KeychainServiceProtocol,
         authSession: AuthSession,
         tokenRefresher: TokenRefresherProtocol? = nil) {
        self.keychainService = keychainService
        self.authSession = authSession
        self.tokenRefresher = tokenRefresher ?? GoogleTokenRefresher(authSession: authSession)
    }

    @MainActor
    convenience init() {
        self.init(keychainService: KeychainService.shared, authSession: .shared)
    }

    // MARK: - Public Methods

    nonisolated func getCurrentToken() async throws -> String {
        // First, try to get token from memory (AuthSession)
        let memoryToken = await MainActor.run { authSession.accessToken }
        if let memoryToken = memoryToken {
            // Verify it's still valid
            if let tokenInfo = try? loadTokenInfo(), !tokenInfo.isExpiringSoon {
                return memoryToken
            }
        }

        // Try to load from keychain
        if let tokenInfo = try? loadTokenInfo(), !tokenInfo.isExpiringSoon {
            // Update memory cache
            await MainActor.run {
                authSession.accessToken = tokenInfo.accessToken
            }
            return tokenInfo.accessToken
        }

        // Token is expired or expiring soon, refresh it
        return try await refreshToken()
    }

    nonisolated func refreshToken() async throws -> String {
        // Use actor-based coordinator to atomically check-and-set refresh task
        let task = await refreshCoordinator.getOrCreateTask { [weak self] in
            Task<String, Error> {
                guard let self = self else {
                    throw TokenManagerError.noValidToken
                }

                await MainActor.run {
                    self.isRefreshing = true
                    self.lastRefreshError = nil
                }

                defer {
                    Task { @MainActor in
                        self.isRefreshing = false
                    }
                    Task {
                        await self.refreshCoordinator.clearTask()
                    }
                }

                return try await self.performTokenRefresh()
            }
        }

        return try await task.value
    }

    nonisolated func saveTokens(access: String, refresh: String?, expirationDate: Date) throws {
        let tokenInfo = TokenInfo(
            accessToken: access,
            refreshToken: refresh,
            expirationDate: expirationDate,
            scope: GoogleConfig.scopes.joined(separator: " ")
        )

        // Save to keychain with afterFirstUnlock to allow background sync when device is locked
        try keychainService.saveCodable(tokenInfo, for: KeychainService.Key.googleAccessToken.rawValue, withAccess: .afterFirstUnlockThisDeviceOnly)

        if let refresh = refresh {
            try keychainService.saveString(refresh, for: KeychainService.Key.googleRefreshToken.rawValue, withAccess: .afterFirstUnlockThisDeviceOnly)
        }

        // Update memory cache
        Task { @MainActor in
            authSession.accessToken = access
        }

        // Reset backoff on successful save
        Task {
            await refreshBackoff.reset()
        }
    }

    nonisolated func clearTokens() throws {
        // Clear from keychain
        try keychainService.delete(for: KeychainService.Key.googleAccessToken.rawValue)
        try keychainService.delete(for: KeychainService.Key.googleRefreshToken.rawValue)

        // Clear from memory
        Task { @MainActor in
            authSession.accessToken = nil
        }
    }

    nonisolated func isAuthenticated() -> Bool {
        // Check if we have valid tokens
        if let tokenInfo = try? loadTokenInfo() {
            return !tokenInfo.isExpired
        }
        return false
    }

    // MARK: - Private Methods

    private nonisolated func performTokenRefresh() async throws -> String {
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

    private nonisolated func loadTokenInfo() throws -> TokenInfo {
        return try keychainService.loadCodable(TokenInfo.self, for: KeychainService.Key.googleAccessToken.rawValue)
    }

    private nonisolated func isRetryableError(_ error: Error) -> Bool {
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

// MARK: - Token Manager + Async Extensions

extension TokenManager {
    nonisolated func withValidToken<T>(_ operation: @escaping (String) async throws -> T) async throws -> T {
        let token = try await getCurrentToken()
        return try await operation(token)
    }

    nonisolated func withTokenRetry<T>(_ operation: @escaping (String) async throws -> T) async throws -> T {
        do {
            let token = try await getCurrentToken()
            return try await operation(token)
        } catch {
            // If operation failed, try refreshing token once and retry
            if isAuthError(error) {
                let newToken = try await refreshToken()
                return try await operation(newToken)
            }
            throw error
        }
    }

    private nonisolated func isAuthError(_ error: Error) -> Bool {
        // Check if error is authentication related
        let nsError = error as NSError
        let authErrorCodes = [401, 403] // Unauthorized, Forbidden

        if let urlError = error as? URLError {
            return urlError.code == .userAuthenticationRequired
        }

        return authErrorCodes.contains(nsError.code)
    }
}
