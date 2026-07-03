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
        try manager.saveTokens(access: "cached-token", refresh: "r", expirationDate: Date().addingTimeInterval(3600))
        let readsAfterSave = keychain.loadCallCount

        for _ in 0..<3 {
            let token = try await manager.getCurrentToken()
            XCTAssertEqual(token, "cached-token")
        }

        XCTAssertEqual(keychain.loadCallCount, readsAfterSave, "validated cache must serve requests without keychain reads")
        XCTAssertEqual(refresher.callCount, 0)
    }

    func testGetCurrentToken_coldCacheReadsKeychainOnceThenCaches() async throws {
        // Seed the keychain through a first manager; a second manager shares
        // the keychain but starts with a cold cache (fresh launch).
        try manager.saveTokens(access: "persisted-token", refresh: "r", expirationDate: Date().addingTimeInterval(3600))
        let coldManager = TokenManager(
            keychainService: keychain,
            authSession: authSession,
            tokenRefresher: refresher
        )
        let readsBefore = keychain.loadCallCount

        let first = try await coldManager.getCurrentToken()
        XCTAssertEqual(first, "persisted-token")
        XCTAssertEqual(keychain.loadCallCount, readsBefore + 1, "cold cache pays exactly one keychain read")

        let second = try await coldManager.getCurrentToken()
        XCTAssertEqual(second, "persisted-token")
        XCTAssertEqual(keychain.loadCallCount, readsBefore + 1, "the read validates the cache for subsequent requests")
    }

    func testClearTokens_invalidatesTheFastPath() async throws {
        try manager.saveTokens(access: "cached-token", refresh: "r", expirationDate: Date().addingTimeInterval(3600))
        _ = try await manager.getCurrentToken()

        try manager.clearTokens()

        refresher.accessToken = "post-signout-token"
        let token = try await manager.getCurrentToken()
        XCTAssertEqual(token, "post-signout-token", "cleared cache must not serve the old token")
        XCTAssertGreaterThanOrEqual(refresher.callCount, 1)
    }

    func testClearTokensRacingKeychainRead_doesNotRepopulateCache() async throws {
        // Sign-out race: getCurrentToken misses the cache and reads the
        // keychain; clearTokens lands after the read returned the old value
        // but before the cache populate. The racing request may still see
        // the old token once (the pre-existing one-request bound), but the
        // cache must stay empty — otherwise the signed-out account's token
        // is served from memory until expiry (~55 minutes).
        try manager.saveTokens(access: "old-token", refresh: "r", expirationDate: Date().addingTimeInterval(3600))
        let coldManager = TokenManager(
            keychainService: keychain,
            authSession: authSession,
            tokenRefresher: refresher
        )
        keychain.onLoad = { [weak keychain, weak coldManager] in
            keychain?.onLoad = nil
            try? coldManager?.clearTokens()
        }

        let raced = try await coldManager.getCurrentToken()
        XCTAssertEqual(raced, "old-token", "the racing request itself may serve the pre-clear token once")

        // Post-clear requests must fall through to refresh (keychain is
        // empty), not the memory cache; a repopulated cache serves old-token.
        refresher.errorToThrow = TokenManagerError.invalidCredentials
        do {
            let leaked = try await coldManager.getCurrentToken()
            XCTFail("cache served the signed-out account's token: \(leaked)")
        } catch {
            // Expected: no cached token, no keychain entry, refresh fails.
        }
        XCTAssertEqual(refresher.callCount, 1, "second request must reach the refresher, not the memory cache")
    }

    func testExpiringSoonCachedToken_triggersRefreshInsteadOfServingStale() async throws {
        // Inside the 5-minute expiring-soon window: the cache must not serve it.
        try manager.saveTokens(access: "stale-token", refresh: "r", expirationDate: Date().addingTimeInterval(60))
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
