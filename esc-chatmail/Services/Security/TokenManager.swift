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
            do {
                let tokenInfo = try loadTokenInfo()
                if !tokenInfo.isExpiringSoon {
                    return memoryToken
                }
            } catch {
                // Memory token exists but keychain read failed - log and continue to refresh
                Log.warning("Keychain read failed while validating memory token", category: .auth)
            }
        }

        // Try to load from keychain
        do {
            let tokenInfo = try loadTokenInfo()
            if !tokenInfo.isExpiringSoon {
                // Update memory cache
                await MainActor.run {
                    authSession.accessToken = tokenInfo.accessToken
                }
                return tokenInfo.accessToken
            }
            // Token is expiring soon, fall through to refresh
        } catch let error as KeychainError {
            // Distinguish between "not found" (expected on first launch) and actual errors
            switch error {
            case .itemNotFound:
                Log.debug("No token found in keychain - will attempt refresh", category: .auth)
            default:
                Log.error("Keychain error loading token info", category: .auth, error: error)
            }
        } catch {
            Log.error("Unexpected error loading token info from keychain", category: .auth, error: error)
        }

        // Token is expired, expiring soon, or not found - refresh it
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

                do {
                    let token = try await self.performTokenRefresh()
                    // Clear state BEFORE returning to prevent race where second caller
                    // gets the completed task before coordinator is cleared
                    await MainActor.run { self.isRefreshing = false }
                    await self.refreshCoordinator.clearTask()
                    return token
                } catch {
                    await MainActor.run { self.isRefreshing = false }
                    await self.refreshCoordinator.clearTask()
                    throw error
                }
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

        // Update memory cache asynchronously
        // Note: This is fire-and-forget by design. The keychain is the source of truth,
        // and getCurrentToken() will load from keychain if memory cache is stale.
        // Making this synchronous would require blocking on MainActor, which could
        // cause deadlocks when called from background contexts.
        Task { @MainActor in
            authSession.accessToken = access
        }

        // Reset backoff on successful save
        // Fire-and-forget is acceptable here as backoff state only affects retry timing
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
        do {
            let tokenInfo = try loadTokenInfo()
            return !tokenInfo.isExpired
        } catch let error as KeychainError {
            // itemNotFound is expected when not authenticated
            if case .itemNotFound = error {
                return false
            }
            Log.warning("Keychain error checking authentication status", category: .auth)
            return false
        } catch {
            Log.warning("Unexpected error checking authentication status", category: .auth)
            return false
        }
    }

}
