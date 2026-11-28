import Foundation
import GoogleSignIn
import Combine

/// What a refresh was started for, which decides who may join it.
enum TokenRefreshPurpose: Equatable, Sendable {
    /// Any token that is fresh by the device's clock: `getCurrentToken`'s
    /// refresh of a token that is missing or about to expire.
    case freshToken
    /// A token other than this one, which Gmail has just answered with 401
    /// (`TokenManager.refreshToken(rejecting:)`). Its refresh asks Google
    /// again, past GoogleSignIn's device-clock check, when GoogleSignIn hands
    /// back this very token.
    case replacing(rejectedAccessToken: String)
}

struct TokenRefreshTaskHandle: Sendable {
    let id: UUID
    let purpose: TokenRefreshPurpose
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
        getOrCreateTask(forGeneration: generation, purpose: .freshToken, factory: factory)
    }

    /// Single-flight per generation. A caller joins the generation's refresh
    /// in flight whatever it was started for, unless `joinsOnlySamePurpose`
    /// is set, when it joins only a refresh started for the same purpose and
    /// otherwise starts its own in the entry's place. That is the second look
    /// of `refreshToken(rejecting:)`: a `.freshToken` refresh it joined first
    /// handed back the rejected token, and joining it again would hand that
    /// token back again.
    func getOrCreateTask(
        forGeneration generation: UInt64,
        purpose: TokenRefreshPurpose,
        joinsOnlySamePurpose: Bool = false,
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
                    purpose: purpose,
                    task: Task { throw CancellationError() }
                )
            }

            if generation == latestGeneration,
               let currentEntry,
               !joinsOnlySamePurpose || currentEntry.handle.purpose == purpose {
                return currentEntry.handle
            }
        }

        let handle = TokenRefreshTaskHandle(id: UUID(), purpose: purpose, task: factory())
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
    /// Google answered a token refresh, GoogleSignIn's own or the forced one,
    /// but AppAuth refused the ID token in that answer
    /// (`OIDErrorCodeIDTokenFailedValidationError`, -15): above all because
    /// its issue time is more than 600 s from the device's clock, or its
    /// expiry has passed by that clock (a clock set ahead). Not
    /// `refreshFailed`, which is retried: asking again cannot change the
    /// device's clock, so it cost three token requests for nothing. Not
    /// `invalidCredentials` either: the grant is fine, and nothing may ask
    /// the user to sign in again or clear the credentials for it. The client
    /// maps it to `APIError.authenticationError`, as before, at a request's
    /// token preflight and on a 401 (`GoogleTokenRefreshFailure`;
    /// architecture review 2026-11, `gap-wall-clock-time#2`).
    case refreshedIDTokenRefused(Error)

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
        case .refreshedIDTokenRefused(let error):
            return "The refreshed sign-in token was refused: \(error.localizedDescription)"
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
        case .refreshedIDTokenRefused:
            return "Check that the device's date and time are set automatically"
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
    /// A token to send in place of `rejectedAccessToken`, which Gmail has
    /// just answered with 401: the cached one where another refresh already
    /// replaced it, else a refresh that asks Google past GoogleSignIn's
    /// device-clock check when GoogleSignIn hands back the rejected token.
    /// Required, with no default: one that forwarded to `refreshToken()`
    /// would bring back the outage it exists for (architecture review
    /// 2026-11, `gap-wall-clock-time#2`).
    func refreshToken(rejecting rejectedAccessToken: String) async throws -> String
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
    ///   (unserialized) keychain read, and refreshToken() and
    ///   refreshToken(rejecting:) snapshot it before entering the coordinator
    ///   and pass it into performTokenRefresh's network calls (the forced
    ///   refresh's included), so a token obtained under a generation that a
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

    /// The cached token, where it is not `rejectedAccessToken` and its
    /// device-clock expiry is not near: another 401's refresh has already
    /// replaced the token this caller sent, and asking Google again would
    /// cost a token request for nothing. Non-private so the refresh
    /// extension asks it again as its task starts, with its generation: a
    /// refresh whose generation was retired is answered with nothing here
    /// (and then cancelled), never with the replacement session's token.
    func cachedReplacement(
        for rejectedAccessToken: String,
        ifCacheEpochMatches epoch: UInt64? = nil
    ) -> String? {
        cacheLock.withLock {
            if let epoch, _cacheEpoch != epoch {
                return nil
            }
            guard let cached = _cachedToken,
                  cached.accessToken != rejectedAccessToken,
                  !cached.isExpiringSoon else {
                return nil
            }
            return cached.accessToken
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
            forGeneration: generation,
            purpose: .freshToken
        ) { [weak self] in
            self?.makeRefreshTask(forGeneration: generation, rejecting: nil)
                ?? Task<String, Error> { throw TokenManagerError.noValidToken }
        }
        return try await awaitRefresh(handle)
    }

    /// The 401 path's refresh (architecture review 2026-11,
    /// `gap-wall-clock-time#2`). `refreshToken()` goes through
    /// `GIDGoogleUser.refreshTokensIfNeeded`, which asks Google only when the
    /// access token's device-clock expiry (or the ID token's `exp`) is within
    /// 60 s, so with the clock set back it handed back the very token Gmail
    /// had rejected, and every request drew two 401s and failed as
    /// `authenticationError` until the token's real expiry passed.
    ///
    /// Three answers, cheapest first. A cached token other than the rejected
    /// one, fresh by the device's clock, is returned at once: another 401
    /// already replaced it. Otherwise this joins the generation's refresh in
    /// flight, whatever it was started for, or starts one for this token
    /// (`TokenRefreshPurpose.replacing`), whose task asks GoogleSignIn and
    /// then, if GoogleSignIn handed back the rejected token, forces a refresh
    /// (`performTokenRefresh`). So a burst of 401s on one token sends one token
    /// request. A refresh it joined that was not started for this token may
    /// hand the rejected token back (a `.freshToken` refresh of the same
    /// stale token); then, and only then, it looks once more and joins only a
    /// refresh for this token, or starts one. The token is saved only through
    /// the epoch-gated save, so a sign-out during either look is a
    /// `CancellationError` like any retired refresh. The result can still be
    /// the rejected token, if Google itself handed it back; the caller decides
    /// what that means (`GmailAPIClient` sends nothing more).
    nonisolated func refreshToken(rejecting rejectedAccessToken: String) async throws -> String {
        if let replacement = cachedReplacement(for: rejectedAccessToken) {
            return replacement
        }

        let generation = cacheEpoch()
        let purpose = TokenRefreshPurpose.replacing(rejectedAccessToken: rejectedAccessToken)
        let joined = await refreshCoordinator.getOrCreateTask(
            forGeneration: generation,
            purpose: purpose
        ) { [weak self] in
            self?.makeRefreshTask(forGeneration: generation, rejecting: rejectedAccessToken)
                ?? Task<String, Error> { throw TokenManagerError.noValidToken }
        }
        let token = try await awaitRefresh(joined)
        guard token == rejectedAccessToken, joined.purpose != purpose else {
            return token
        }

        Log.info("A refresh joined after a 401 returned the rejected token; forcing one", category: .auth)
        let forcing = await refreshCoordinator.getOrCreateTask(
            forGeneration: generation,
            purpose: purpose,
            joinsOnlySamePurpose: true
        ) { [weak self] in
            self?.makeRefreshTask(forGeneration: generation, rejecting: rejectedAccessToken)
                ?? Task<String, Error> { throw TokenManagerError.noValidToken }
        }
        return try await awaitRefresh(forcing)
    }

    private nonisolated func makeRefreshTask(
        forGeneration generation: UInt64,
        rejecting rejectedAccessToken: String?
    ) -> Task<String, Error> {
        Task<String, Error> { [weak self] in
            guard let self = self else {
                throw TokenManagerError.noValidToken
            }

            await MainActor.run {
                self.isRefreshing = true
                self.lastRefreshError = nil
            }

            return try await self.performTokenRefresh(
                ifCacheEpochMatches: generation,
                rejecting: rejectedAccessToken
            )
        }
    }

    private nonisolated func awaitRefresh(_ handle: TokenRefreshTaskHandle) async throws -> String {
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
