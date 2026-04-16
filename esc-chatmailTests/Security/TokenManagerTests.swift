import XCTest
@testable import esc_chatmail

@MainActor
final class TokenManagerTests: XCTestCase {

    private var mockKeychain: MockKeychainService!
    private var mockRefresher: MockTokenRefresher!
    private var authSession: AuthSession!
    private var sut: TokenManager!

    override func setUp() async throws {
        try await super.setUp()
        mockKeychain = MockKeychainService()
        mockRefresher = MockTokenRefresher()
        let testDefaults = UserDefaults(suiteName: "TokenManagerTests-\(UUID().uuidString)")!
        let placeholderTokenManager = MockTokenManager()
        authSession = AuthSession(
            tokenManagerProvider: { placeholderTokenManager },
            keychainService: mockKeychain,
            userDefaults: testDefaults,
            clearConversationCaches: {},
            cleanupDownloads: {},
            resetCoreDataStore: {},
            clearAttachmentCache: {}
        )
        sut = TokenManager(
            keychainService: mockKeychain,
            authSession: authSession,
            tokenRefresher: mockRefresher
        )
    }

    override func tearDown() async throws {
        sut = nil
        authSession = nil
        mockRefresher = nil
        mockKeychain = nil
        try await super.tearDown()
    }

    // MARK: - saveTokens

    func testSaveTokens_persistsAccessTokenToKeychain() async throws {
        let expiration = Date().addingTimeInterval(3600)
        try sut.saveTokens(access: "access-1", refresh: "refresh-1", expirationDate: expiration)

        let stored = try mockKeychain.loadCodable(
            TokenInfo.self,
            for: KeychainService.Key.googleAccessToken.rawValue
        )
        XCTAssertEqual(stored.accessToken, "access-1")
        XCTAssertEqual(stored.refreshToken, "refresh-1")
        XCTAssertEqual(stored.expirationDate.timeIntervalSince1970, expiration.timeIntervalSince1970, accuracy: 0.001)
    }

    func testSaveTokens_persistsRefreshTokenSeparately() throws {
        try sut.saveTokens(access: "a", refresh: "refresh-xyz", expirationDate: Date().addingTimeInterval(3600))

        let stored = try mockKeychain.loadString(for: KeychainService.Key.googleRefreshToken.rawValue)
        XCTAssertEqual(stored, "refresh-xyz")
    }

    func testSaveTokens_nilRefreshToken_doesNotWriteRefreshEntry() throws {
        try sut.saveTokens(access: "a", refresh: nil, expirationDate: Date().addingTimeInterval(3600))

        XCTAssertFalse(mockKeychain.exists(for: KeychainService.Key.googleRefreshToken.rawValue))
    }

    func testSaveTokens_updatesInMemoryAuthSessionAccessToken() async throws {
        try sut.saveTokens(access: "memory-cached", refresh: nil, expirationDate: Date().addingTimeInterval(3600))

        // saveTokens updates memory cache via a fire-and-forget Task { @MainActor }.
        // Spin the runloop briefly to allow the hop.
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(authSession.accessToken, "memory-cached")
    }

    // MARK: - clearTokens

    func testClearTokens_removesAccessAndRefreshFromKeychain() throws {
        try sut.saveTokens(access: "a", refresh: "r", expirationDate: Date().addingTimeInterval(3600))

        try sut.clearTokens()

        XCTAssertFalse(mockKeychain.exists(for: KeychainService.Key.googleAccessToken.rawValue))
        XCTAssertFalse(mockKeychain.exists(for: KeychainService.Key.googleRefreshToken.rawValue))
    }

    func testClearTokens_clearsInMemoryAuthSessionAccessToken() async throws {
        authSession.accessToken = "cached"
        try sut.saveTokens(access: "cached", refresh: nil, expirationDate: Date().addingTimeInterval(3600))
        try await Task.sleep(nanoseconds: 50_000_000)

        try sut.clearTokens()

        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertNil(authSession.accessToken)
    }

    // MARK: - isAuthenticated

    func testIsAuthenticated_noStoredToken_returnsFalse() {
        XCTAssertFalse(sut.isAuthenticated())
    }

    func testIsAuthenticated_validToken_returnsTrue() throws {
        try sut.saveTokens(access: "a", refresh: nil, expirationDate: Date().addingTimeInterval(3600))
        XCTAssertTrue(sut.isAuthenticated())
    }

    func testIsAuthenticated_expiredToken_returnsFalse() throws {
        try sut.saveTokens(access: "a", refresh: nil, expirationDate: Date().addingTimeInterval(-60))
        XCTAssertFalse(sut.isAuthenticated())
    }

    // MARK: - getCurrentToken

    func testGetCurrentToken_freshKeychainToken_returnsItWithoutRefresh() async throws {
        try sut.saveTokens(access: "stored", refresh: nil, expirationDate: Date().addingTimeInterval(3600))

        // Clear in-memory cache so getCurrentToken has to read keychain
        authSession.accessToken = nil

        let token = try await sut.getCurrentToken()

        XCTAssertEqual(token, "stored")
        XCTAssertEqual(mockRefresher.callCount, 0)
    }

    func testGetCurrentToken_noStoredToken_triggersRefresh() async throws {
        mockRefresher.accessToken = "fresh-after-refresh"
        mockRefresher.expirationDate = Date().addingTimeInterval(3600)

        let token = try await sut.getCurrentToken()

        XCTAssertEqual(token, "fresh-after-refresh")
        XCTAssertEqual(mockRefresher.callCount, 1)
    }

    func testGetCurrentToken_expiringSoonToken_triggersRefresh() async throws {
        // Token expires in 1 minute — inside the 5-minute "expiring soon" window.
        try sut.saveTokens(access: "soon-expiring", refresh: nil, expirationDate: Date().addingTimeInterval(60))
        authSession.accessToken = nil

        mockRefresher.accessToken = "refreshed"
        mockRefresher.expirationDate = Date().addingTimeInterval(3600)

        let token = try await sut.getCurrentToken()

        XCTAssertEqual(token, "refreshed")
        XCTAssertEqual(mockRefresher.callCount, 1)
    }

    // MARK: - refreshToken (single-flight)

    func testRefreshToken_concurrentCallers_shareSingleRefreshRequest() async throws {
        mockRefresher.accessToken = "shared"
        mockRefresher.expirationDate = Date().addingTimeInterval(3600)
        mockRefresher.artificialDelay = 0.1 // Hold refresh open long enough for coordinator to dedup

        async let a = sut.refreshToken()
        async let b = sut.refreshToken()
        async let c = sut.refreshToken()

        let tokenA = try await a
        let tokenB = try await b
        let tokenC = try await c

        XCTAssertEqual([tokenA, tokenB, tokenC], ["shared", "shared", "shared"])
        XCTAssertEqual(mockRefresher.callCount, 1, "Three concurrent callers must share one refresh")
    }

    func testRefreshToken_persistsNewTokenToKeychain() async throws {
        mockRefresher.accessToken = "brand-new"
        mockRefresher.refreshToken = "new-refresh"
        mockRefresher.expirationDate = Date().addingTimeInterval(3600)

        _ = try await sut.refreshToken()

        let stored = try mockKeychain.loadCodable(
            TokenInfo.self,
            for: KeychainService.Key.googleAccessToken.rawValue
        )
        XCTAssertEqual(stored.accessToken, "brand-new")
    }

    // MARK: - refreshToken error classification

    func testRefreshToken_invalidCredentialsError_doesNotRetry() async {
        mockRefresher.errorToThrow = TokenManagerError.invalidCredentials

        do {
            _ = try await sut.refreshToken()
            XCTFail("Expected throw")
        } catch let error as TokenManagerError {
            guard case .invalidCredentials = error else {
                return XCTFail("Expected .invalidCredentials, got \(error)")
            }
            XCTAssertEqual(mockRefresher.callCount, 1, "Non-retryable errors should not retry")
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    func testRefreshToken_noValidTokenError_doesNotRetry() async {
        mockRefresher.errorToThrow = TokenManagerError.noValidToken

        do {
            _ = try await sut.refreshToken()
            XCTFail("Expected throw")
        } catch {
            XCTAssertEqual(mockRefresher.callCount, 1)
        }
    }

    func testRefreshToken_updatesMemoryCacheBeforeReturning() async throws {
        mockRefresher.accessToken = "in-memory"
        mockRefresher.expirationDate = Date().addingTimeInterval(3600)

        _ = try await sut.refreshToken()

        XCTAssertEqual(authSession.accessToken, "in-memory")
    }

    // MARK: - isRetryableError

    func testIsRetryableError_networkUnavailable_isRetryable() {
        XCTAssertTrue(sut.isRetryableError(TokenManagerError.networkUnavailable))
    }

    func testIsRetryableError_rateLimitExceeded_isRetryable() {
        XCTAssertTrue(sut.isRetryableError(TokenManagerError.rateLimitExceeded))
    }

    func testIsRetryableError_noValidToken_isNotRetryable() {
        XCTAssertFalse(sut.isRetryableError(TokenManagerError.noValidToken))
    }

    func testIsRetryableError_invalidCredentials_isNotRetryable() {
        XCTAssertFalse(sut.isRetryableError(TokenManagerError.invalidCredentials))
    }

    func testIsRetryableError_tokenExpired_isNotRetryable() {
        XCTAssertFalse(sut.isRetryableError(TokenManagerError.tokenExpired))
    }

    func testIsRetryableError_invalidGrantUnderlying_isNotRetryable() {
        let underlying = NSError(domain: "GTMSessionFetcher", code: 400, userInfo: ["error": "invalid_grant"])
        let wrapped = TokenManagerError.refreshFailed(underlying)
        XCTAssertFalse(sut.isRetryableError(wrapped),
                       "Refresh tokens revoked (invalid_grant) must not be retried")
    }

    func testIsRetryableError_genericRefreshFailed_isRetryable() {
        let underlying = NSError(domain: "Transient", code: 503)
        let wrapped = TokenManagerError.refreshFailed(underlying)
        XCTAssertTrue(sut.isRetryableError(wrapped))
    }

    func testIsRetryableError_urlErrorTimedOut_isRetryable() {
        let error = NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut)
        XCTAssertTrue(sut.isRetryableError(error))
    }

    func testIsRetryableError_urlErrorNotConnected_isRetryable() {
        let error = NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet)
        XCTAssertTrue(sut.isRetryableError(error))
    }

    func testIsRetryableError_unknownDomainCode_isNotRetryable() {
        let error = NSError(domain: "Unknown", code: 9999)
        XCTAssertFalse(sut.isRetryableError(error))
    }

    // MARK: - isAuthError

    func testIsAuthError_401_returnsTrue() {
        let error = NSError(domain: "HTTP", code: 401)
        XCTAssertTrue(sut.isAuthError(error))
    }

    func testIsAuthError_403_returnsTrue() {
        let error = NSError(domain: "HTTP", code: 403)
        XCTAssertTrue(sut.isAuthError(error))
    }

    func testIsAuthError_500_returnsFalse() {
        let error = NSError(domain: "HTTP", code: 500)
        XCTAssertFalse(sut.isAuthError(error))
    }

    func testIsAuthError_urlErrorUserAuthRequired_returnsTrue() {
        let error = URLError(.userAuthenticationRequired)
        XCTAssertTrue(sut.isAuthError(error))
    }
}
