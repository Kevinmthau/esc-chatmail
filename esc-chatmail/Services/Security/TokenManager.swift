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

protocol TokenManagerProtocol: Sendable {
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

    @MainActor @Published var isRefreshing = false
    @MainActor @Published var lastRefreshError: Error?

    let keychainService: KeychainServiceProtocol
    private let authSession: AuthSession
    private let refreshCoordinator = TaskCoordinator<String>()
    let refreshBackoff = ExponentialBackoffActor()
    let tokenRefresher: TokenRefresherProtocol

    // Token refresh configuration
    let maxRetryAttempts = 3

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

}
