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

    // MARK: - In-memory token cache

    /// Validated (token, expiry) pair for the request fast path.
    private struct CachedToken {
        let accessToken: String
        let expirationDate: Date

        var isExpiringSoon: Bool {
            Date().addingTimeInterval(300) >= expirationDate
        }
    }

    /// Lock-protected so getCurrentToken serves requests without a keychain
    /// round-trip or a MainActor hop (the previous fast path stored only the
    /// token in @MainActor AuthSession and re-read the keychain per request
    /// to validate expiry). Every writer either supplies the expiry or clears
    /// the cache (unvalidated → keychain fallback).
    private let cacheLock = NSLock()
    private var _cachedToken: CachedToken?
    /// Bumped by every cache clear. getCurrentToken snapshots it before its
    /// keychain read and re-checks it when populating, so a read that raced
    /// clearTokens (sign-out) cannot resurrect the cleared token in memory.
    private var _cacheEpoch: UInt64 = 0

    private func cachedToken() -> CachedToken? {
        cacheLock.withLock { _cachedToken }
    }

    private func cacheEpoch() -> UInt64 {
        cacheLock.withLock { _cacheEpoch }
    }

    private func setCachedToken(_ token: CachedToken?) {
        cacheLock.withLock {
            if token == nil {
                _cacheEpoch &+= 1
            }
            _cachedToken = token
        }
    }

    /// Populates the cache only if no clear happened since `epoch` was
    /// snapshotted. Returns whether the write was applied.
    @discardableResult
    private func setCachedToken(_ token: CachedToken, ifEpochMatches epoch: UInt64) -> Bool {
        cacheLock.withLock {
            guard _cacheEpoch == epoch else { return false }
            _cachedToken = token
            return true
        }
    }

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

    /// Updates the in-memory caches: the lock-protected (token, expiry) pair
    /// that serves the request fast path, and AuthSession's @Published token
    /// for UI consumers. A nil expiry marks the cache unvalidated so
    /// getCurrentToken falls back to the keychain.
    func updateMemoryCache(accessToken: String, expirationDate: Date?) async {
        if let expirationDate {
            setCachedToken(CachedToken(accessToken: accessToken, expirationDate: expirationDate))
        } else {
            setCachedToken(nil)
        }
        await MainActor.run {
            authSession.accessToken = accessToken
        }
    }

    // MARK: - Public Methods

    nonisolated func getCurrentToken() async throws -> String {
        // Fast path: validated in-memory (token, expiry) — no keychain read,
        // no MainActor hop.
        if let cached = cachedToken(), !cached.isExpiringSoon {
            return cached.accessToken
        }

        // Try to load from keychain. Snapshot the cache epoch first: if
        // clearTokens runs while the read is in flight, the populate below is
        // dropped instead of caching the signed-out account's token until
        // expiry (matching the pre-cache bound, where staleness was limited
        // to the one request that raced the clear).
        let epoch = cacheEpoch()
        do {
            let tokenInfo = try loadTokenInfo()
            if !tokenInfo.isExpiringSoon {
                // Update memory caches, unless a clear raced the keychain read
                if setCachedToken(CachedToken(
                    accessToken: tokenInfo.accessToken,
                    expirationDate: tokenInfo.expirationDate
                ), ifEpochMatches: epoch) {
                    await MainActor.run {
                        authSession.accessToken = tokenInfo.accessToken
                    }
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

        // Validate the lock-protected cache synchronously — this is what
        // getCurrentToken's fast path reads. The AuthSession publish below
        // stays fire-and-forget by design: it only feeds UI observers, and
        // making it synchronous would require blocking on MainActor, which
        // could deadlock when called from background contexts.
        setCachedToken(CachedToken(accessToken: access, expirationDate: expirationDate))
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
        // Invalidate the request fast path FIRST (bumping the cache epoch) so
        // no request can win a stale token: a getCurrentToken that already
        // read the keychain before the deletes below fails the epoch check
        // and cannot repopulate the cache with the signed-out token.
        setCachedToken(nil)

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
