import Foundation
import GoogleSignIn
import Combine

struct TokenRefreshTaskHandle: Sendable {
    let id: UUID
    let task: Task<String, Error>
}

actor TokenRefreshCoordinator {
    private struct Entry {
        let generation: UInt64
        let handle: TokenRefreshTaskHandle
    }

    private var currentEntry: Entry?
    private var latestGeneration: UInt64?

    func getOrCreateTask(
        forGeneration generation: UInt64,
        factory: () -> Task<String, Error>
    ) -> TokenRefreshTaskHandle {
        if let latestGeneration {
            if generation < latestGeneration {
                // A caller can snapshot an old generation, suspend before
                // reaching this actor, then arrive after a replacement
                // account has installed its task. Never let that stale caller
                // evict the newer single-flight entry.
                return TokenRefreshTaskHandle(
                    id: UUID(),
                    task: Task { throw CancellationError() }
                )
            }

            if generation == latestGeneration,
               let currentEntry {
                return currentEntry.handle
            }
        }

        let handle = TokenRefreshTaskHandle(id: UUID(), task: factory())
        latestGeneration = generation
        currentEntry = Entry(generation: generation, handle: handle)
        return handle
    }

    /// Returns true only when this handle still owns the active generation.
    func clearTask(id: UUID) -> Bool {
        guard currentEntry?.handle.id == id else { return false }
        currentEntry = nil
        return true
    }
}

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
/// - Internal coordination uses a dedicated actor (TokenRefreshCoordinator)
/// - Nonisolated methods are carefully designed to not access mutable state directly
/// - ObservableObject pattern requires class semantics with Sendable conformance
final class TokenManager: ObservableObject, TokenManagerProtocol, @unchecked Sendable {
    @MainActor static let shared: TokenManager = TokenManager()

    @MainActor @Published var isRefreshing = false
    @MainActor @Published var lastRefreshError: Error?

    let keychainService: KeychainServiceProtocol
    private let authSession: AuthSession
    private let refreshCoordinator = TokenRefreshCoordinator()
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
    /// to validate expiry).
    ///
    /// Writer discipline (sign-out consistency):
    /// - The lock guards the cached pair, a sign-out epoch, AND the keychain
    ///   writes/deletes of the two writers (saveTokens, clearTokens), so a
    ///   save and a clear can never interleave their keychain operations.
    /// - BOTH writers bump the epoch under the lock: clearTokens always, and
    ///   ungated saveTokens (sign-in/restore via
    ///   persistSessionForBackgroundAccess) so in-flight refreshes for the
    ///   prior credentials cancel instead of publishing. Cache populates are
    ///   epoch-gated: getCurrentToken snapshots the epoch before its
    ///   (unserialized) keychain read, and refreshToken() snapshots it before
    ///   entering the coordinator and passes it into performTokenRefresh's
    ///   network call, so a token obtained under a generation that a
    ///   sign-out or replacement sign-in has since retired is dropped instead
    ///   of cached — with the reader's populate serialized against the whole
    ///   clear section, no interleaving can resurrect a cleared token.
    private let cacheLock = NSLock()
    private var _cachedToken: CachedToken?
    private var _cacheEpoch: UInt64 = 0

    private func cachedToken() -> CachedToken? {
        cacheLock.withLock { _cachedToken }
    }

    /// Non-private so the refresh extension (TokenManager+Refresh) can
    /// snapshot the sign-out generation before its network call.
    func cacheEpoch() -> UInt64 {
        cacheLock.withLock { _cacheEpoch }
    }

    func cacheEpochMatches(_ epoch: UInt64) -> Bool {
        cacheLock.withLock { _cacheEpoch == epoch }
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
                        // Re-check under the MainActor hop: a clear that landed
                        // after the populate must not have its nil-publish
                        // overwritten with the retired token.
                        if cacheEpochMatches(epoch),
                           cachedToken()?.accessToken == tokenInfo.accessToken {
                            authSession.accessToken = tokenInfo.accessToken
                        }
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
        // Refreshes are single-flight only within one credential generation.
        // A replacement sign-in must never join the retired account's task.
        let generation = cacheEpoch()
        let handle = await refreshCoordinator.getOrCreateTask(
            forGeneration: generation
        ) { [weak self] in
            Task<String, Error> {
                guard let self = self else {
                    throw TokenManagerError.noValidToken
                }

                await MainActor.run {
                    self.isRefreshing = true
                    self.lastRefreshError = nil
                }

                return try await self.performTokenRefresh(
                    ifCacheEpochMatches: generation
                )
            }
        }

        do {
            let token = try await handle.task.value
            if await refreshCoordinator.clearTask(id: handle.id) {
                await MainActor.run { self.isRefreshing = false }
            }
            return token
        } catch {
            if await refreshCoordinator.clearTask(id: handle.id) {
                await MainActor.run { self.isRefreshing = false }
            }
            throw error
        }
    }

    nonisolated func saveTokens(access: String, refresh: String?, expirationDate: Date) throws {
        // Direct saves (sign-in flows) are ungated: they establish the new
        // sign-in generation rather than racing an old one.
        try saveTokens(access: access, refresh: refresh, expirationDate: expirationDate, ifCacheEpochMatches: nil)
    }

    /// Writer core. When `epoch` is non-nil and a clearTokens (sign-out) has
    /// bumped the epoch since the caller snapshotted it, NOTHING is written —
    /// no keychain entries, no cache, no AuthSession publish — and the method
    /// returns false: the tokens belong to a retired sign-in generation, and
    /// persisting them would resurrect the signed-out account (in the worst
    /// case across relaunch, via isAuthenticated() reading the keychain).
    /// Keychain writes happen inside the cache lock so they can never
    /// interleave with clearTokens' deletes.
    @discardableResult
    nonisolated func saveTokens(
        access: String,
        refresh: String?,
        expirationDate: Date,
        ifCacheEpochMatches epoch: UInt64?
    ) throws -> Bool {
        let tokenInfo = TokenInfo(
            accessToken: access,
            refreshToken: refresh,
            expirationDate: expirationDate,
            scope: GoogleConfig.scopes.joined(separator: " ")
        )

        let appliedGeneration: UInt64? = try cacheLock.withLock {
            if let epoch, _cacheEpoch != epoch {
                return nil
            }

            // An ungated save establishes a new interactive/restore session.
            // Retire every refresh that began under the previous credentials
            // before writing the replacement token set.
            if epoch == nil {
                _cacheEpoch &+= 1
            }

            // Save to keychain with afterFirstUnlock to allow background sync
            // when device is locked
            try keychainService.saveCodable(tokenInfo, for: KeychainService.Key.googleAccessToken.rawValue, withAccess: .afterFirstUnlockThisDeviceOnly)

            if let refresh = refresh {
                try keychainService.saveString(refresh, for: KeychainService.Key.googleRefreshToken.rawValue, withAccess: .afterFirstUnlockThisDeviceOnly)
            }

            // Validate the cache synchronously — this is what getCurrentToken's
            // fast path reads.
            _cachedToken = CachedToken(accessToken: access, expirationDate: expirationDate)
            return _cacheEpoch
        }

        guard let appliedGeneration else { return false }

        // The AuthSession publish stays fire-and-forget by design: it only
        // feeds UI observers, and making it synchronous would require
        // blocking on MainActor, which could deadlock when called from
        // background contexts. It re-reads the cache so a clear that lands
        // before the hop is not overwritten with the stale token.
        Task { @MainActor in
            if self.cacheEpochMatches(appliedGeneration),
               self.cachedToken()?.accessToken == access {
                self.authSession.accessToken = access
            }
        }

        return true
    }

    nonisolated func clearTokens() throws {
        // One critical section retires the sign-in generation: bump the
        // epoch (dropping every in-flight epoch-gated populate), clear the
        // fast path, and delete the keychain entries before any other writer
        // or reader-populate can run. getCurrentToken's keychain READ is not
        // serialized with this, but its populate is epoch-gated and cannot
        // land mid-section, so a read that saw the pre-delete keychain can
        // never re-cache the signed-out token.
        try cacheLock.withLock {
            _cacheEpoch &+= 1
            _cachedToken = nil

            try keychainService.delete(for: KeychainService.Key.googleAccessToken.rawValue)
            try keychainService.delete(for: KeychainService.Key.googleRefreshToken.rawValue)
        }

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

    /// Publishes a terminal refresh-token verdict without signing out or
    /// deleting the isolated local mailbox. Interactive authentication can
    /// then repair the session while preserving durable pending actions.
    func publishCredentialRevocation(ifCacheEpochMatches epoch: UInt64) async {
        await MainActor.run {
            guard self.cacheEpochMatches(epoch) else { return }
            authSession.requireReauthentication()
        }
    }

}
