import XCTest
@testable import esc_chatmail

/// Pins the in-memory (token, expiry) fast path: requests must not pay a
/// keychain read (or refresh) while a validated token is cached, and every
/// cache writer must keep the fast path truthful.
@MainActor
final class TokenManagerCacheTests: XCTestCase {

    private var keychain: MockKeychainService!
    private var refresher: MockTokenRefresher!
    private var authSession: AuthSession!
    private var manager: TokenManager!

    override func setUp() {
        super.setUp()
        keychain = MockKeychainService()
        refresher = MockTokenRefresher()
        authSession = AuthSession(
            tokenManagerProvider: { [weak self] in self!.manager },
            keychainService: keychain,
            userDefaults: UserDefaults(suiteName: "TokenManagerCacheTests.\(UUID().uuidString)")!,
            clearConversationCaches: {},
            cleanupDownloads: {},
            resetCoreDataStore: {},
            clearAttachmentCache: {}
        )
        manager = TokenManager(
            keychainService: keychain,
            authSession: authSession,
            tokenRefresher: refresher
        )
    }

    override func tearDown() {
        manager = nil
        authSession = nil
        refresher = nil
        keychain = nil
        super.tearDown()
    }

    func testGetCurrentToken_servesFromMemoryWithoutKeychainReads() async throws {
        manager.adoptTokens(access: "cached-token", expirationDate: Date().addingTimeInterval(3600))
        let readsAfterSave = keychain.loadCallCount

        for _ in 0..<3 {
            let token = try await manager.getCurrentToken()
            XCTAssertEqual(token, "cached-token")
        }

        XCTAssertEqual(keychain.loadCallCount, readsAfterSave, "validated cache must serve requests without keychain reads")
        XCTAssertEqual(refresher.callCount, 0)
    }

    // Revert-check: fails if `getCurrentToken` reads the keychain on a cold
    // cache again. A launch fills the cache through the restore's adoption,
    // and a cache that is empty all the same is filled by the refresh, which
    // asks GoogleSignIn, never by a copy in the keychain (architecture review
    // 2026-11, `account-boundary-auth#4`).
    func testGetCurrentToken_coldCache_isFilledByTheRefreshNeverByTheKeychain() async throws {
        // A second manager shares the keychain, which holds an earlier build's
        // items, and starts with a cold cache (a fresh launch).
        try LegacyTokenItems.seed(in: keychain, accessToken: "persisted-token")
        let coldManager = TokenManager(
            keychainService: keychain,
            authSession: authSession,
            tokenRefresher: refresher
        )
        refresher.accessToken = "from-google-sign-in"
        refresher.expirationDate = Date().addingTimeInterval(3600)
        let readsBefore = keychain.loadCallCount

        let first = try await coldManager.getCurrentToken()
        XCTAssertEqual(first, "from-google-sign-in")

        let second = try await coldManager.getCurrentToken()
        XCTAssertEqual(second, "from-google-sign-in")
        XCTAssertEqual(refresher.callCount, 1, "the refresh validates the cache for subsequent requests")
        XCTAssertEqual(keychain.loadCallCount, readsBefore, "a cold cache reads nothing from the keychain")
    }

    func testClearTokens_invalidatesTheFastPath() async throws {
        manager.adoptTokens(access: "cached-token", expirationDate: Date().addingTimeInterval(3600))
        _ = try await manager.getCurrentToken()

        try manager.clearTokens()

        refresher.accessToken = "post-signout-token"
        let token = try await manager.getCurrentToken()
        XCTAssertEqual(token, "post-signout-token", "cleared cache must not serve the old token")
        XCTAssertGreaterThanOrEqual(refresher.callCount, 1)
    }

    func testAdoptTokensGatedOnRetiredEpoch_changesNothing() throws {
        // A refresh that finishes after sign-out carries the retired
        // generation's epoch; its adoption must not fill the cache, or the
        // next request would be handed the signed-out account's token.
        manager.adoptTokens(access: "old", expirationDate: Date().addingTimeInterval(3600))
        let epoch = manager.cacheEpoch()
        try manager.clearTokens() // bumps the epoch, clears the cache

        let applied = manager.adoptTokens(
            access: "refreshed",
            expirationDate: Date().addingTimeInterval(3600),
            ifCacheEpochMatches: epoch
        )

        XCTAssertFalse(applied, "an adoption gated on a retired sign-in generation must not apply")
        XCTAssertFalse(manager.isAuthenticated())
        XCTAssertEqual(keychain.saveCallCount, 0)
    }

    // Revert-check: the CancellationError expectation fails if performTokenRefresh
    // stops throwing when `adoptTokens(access:expirationDate:ifCacheEpochMatches:)`
    // reports `adopted == false` — the pre-branch code logged and handed the
    // triggering request its token once. A retired generation must yield no
    // usable token at all; this is TokenManager's half of the same
    // retired-generation rejection TokenRefreshCoordinator applies to callers
    // that joined the refresh.
    func testRefreshCompletingAfterSignOut_doesNotResurrectAccount() async throws {
        // getCurrentToken must refresh (seeded token is inside the 5-min
        // window), and sign-out lands mid-refresh — after performTokenRefresh
        // snapshots the epoch, before it saves. The retired request must be
        // canceled so it cannot execute account work with any returned token.
        manager.adoptTokens(access: "old", expirationDate: Date().addingTimeInterval(60))
        refresher.accessToken = "refreshed"
        refresher.refreshToken = "refreshed-r"
        refresher.expirationDate = Date().addingTimeInterval(3600)
        refresher.onRefresh = { [weak manager] in
            try? manager?.clearTokens()
        }

        do {
            _ = try await manager.getCurrentToken()
            XCTFail("Expected the retired refresh to be cancelled")
        } catch is CancellationError {
            // Expected.
        }

        // The refresh's adoption saw the bumped epoch and dropped: nothing
        // cached, and nothing written for a later launch to find.
        XCTAssertFalse(manager.isAuthenticated())
        XCTAssertEqual(keychain.saveCallCount, 0)
    }

    // Revert-check: fails if adoptTokens drops the `if epoch == nil { _cacheEpoch &+= 1 }`
    // bump on ungated (interactive/restore) adoptions. Without it the in-flight
    // refresh's gated adoption still matches its snapshotted epoch, so the retired
    // account's "stale-refresh" token overwrites the replacement sign-in's in
    // the cache and the next getCurrentToken serves the wrong account's token.
    func testRefreshCompletingAfterReplacementSignInDoesNotOverwriteNewTokens() async throws {
        manager.adoptTokens(
            access: "old",
            expirationDate: Date().addingTimeInterval(60)
        )
        refresher.accessToken = "stale-refresh"
        refresher.refreshToken = "stale-refresh-r"
        refresher.expirationDate = Date().addingTimeInterval(3_600)
        refresher.onRefresh = { [weak manager] in
            manager?.adoptTokens(
                access: "replacement",
                expirationDate: Date().addingTimeInterval(3_600)
            )
        }

        do {
            _ = try await manager.getCurrentToken()
            XCTFail("Expected the retired refresh to be cancelled")
        } catch is CancellationError {
            // Expected.
        }

        let currentToken = try await manager.getCurrentToken()
        XCTAssertEqual(currentToken, "replacement")
    }

    func testExpiringSoonCachedToken_triggersRefreshInsteadOfServingStale() async throws {
        // Inside the 5-minute expiring-soon window: the cache must not serve it.
        manager.adoptTokens(access: "stale-token", expirationDate: Date().addingTimeInterval(60))
        refresher.accessToken = "fresh-token"
        refresher.expirationDate = Date().addingTimeInterval(3600)

        let token = try await manager.getCurrentToken()

        XCTAssertEqual(token, "fresh-token")
        XCTAssertEqual(refresher.callCount, 1)

        // The refresh validated the cache; subsequent requests stay in memory.
        let readsAfterRefresh = keychain.loadCallCount
        let again = try await manager.getCurrentToken()
        XCTAssertEqual(again, "fresh-token")
        XCTAssertEqual(keychain.loadCallCount, readsAfterRefresh)
    }
}
