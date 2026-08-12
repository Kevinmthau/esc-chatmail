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

    private func waitForAccessToken(
        _ expected: String?,
        timeout: TimeInterval = 1.0,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let deadline = Date().addingTimeInterval(timeout)

        while Date() < deadline {
            if authSession.accessToken == expected {
                return
            }

            await Task.yield()
            try? await Task.sleep(nanoseconds: 10_000_000)
        }

        let expectedDescription = expected.map { String(reflecting: $0) } ?? "nil"
        let actualDescription = authSession.accessToken.map { String(reflecting: $0) } ?? "nil"
        XCTFail(
            "Timed out waiting for authSession.accessToken to become \(expectedDescription); current value was \(actualDescription)",
            file: file,
            line: line
        )
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

        await waitForAccessToken("memory-cached")
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
        await waitForAccessToken("cached")

        try sut.clearTokens()

        await waitForAccessToken(nil)
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
        await waitForAccessToken("stored")

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
        authSession.isAuthenticated = true
        mockRefresher.errorToThrow = TokenManagerError.invalidCredentials

        do {
            _ = try await sut.refreshToken()
            XCTFail("Expected throw")
        } catch let error as TokenManagerError {
            guard case .invalidCredentials = error else {
                return XCTFail("Expected .invalidCredentials, got \(error)")
            }
            XCTAssertEqual(mockRefresher.callCount, 1, "Non-retryable errors should not retry")
            XCTAssertTrue(authSession.requiresReauthentication)
            XCTAssertFalse(authSession.canAccessMailbox)
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    // Revert-check: fails if performTokenRefresh's non-retryable branch stops
    // unwrapping `TokenManagerError.refreshFailed(underlying)` before asking
    // isInvalidGrantError, or stops calling publishCredentialRevocation. The
    // old code classified the wrapper itself, which carries neither code 400
    // nor the userInfo, so a revoked grant surfaced as a generic .refreshFailed
    // and the mailbox kept retrying instead of asking for reauthentication.
    func testRefreshToken_invalidGrantRequiresReauthenticationWithoutRetry() async {
        authSession.isAuthenticated = true
        let underlying = NSError(
            domain: "GTMSessionFetcher",
            code: 400,
            userInfo: ["error": "invalid_grant"]
        )
        mockRefresher.errorToThrow = TokenManagerError.refreshFailed(underlying)

        do {
            _ = try await sut.refreshToken()
            XCTFail("Expected throw")
        } catch let error as TokenManagerError {
            guard case .invalidCredentials = error else {
                return XCTFail("Expected .invalidCredentials, got \(error)")
            }
            XCTAssertEqual(mockRefresher.callCount, 1)
            XCTAssertTrue(authSession.requiresReauthentication)
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    // Revert-check: fails if TokenManager.isInvalidGrantError loses its AppAuth
    // handling — the `org.openid.appauth.oauth_token` / code -10 pair and the
    // nested OIDOAuthErrorResponseErrorKey lookup. The legacy `code == 400`
    // check matches neither shape, so an AppAuth-reported revocation would
    // never park the mailbox.
    // HONEST SCOPE: the fixture carries both shapes, so removing either branch
    // alone still passes; this pins that detection exists, not which branch does it.
    func testRefreshToken_appAuthInvalidGrantRequiresReauthenticationWithoutRetry() async {
        authSession.isAuthenticated = true
        let underlying = NSError(
            domain: "org.openid.appauth.oauth_token",
            code: -10,
            userInfo: [
                "OIDOAuthErrorResponseErrorKey": ["error": "invalid_grant"]
            ]
        )
        mockRefresher.errorToThrow = TokenManagerError.refreshFailed(underlying)

        do {
            _ = try await sut.refreshToken()
            XCTFail("Expected throw")
        } catch let error as TokenManagerError {
            guard case .invalidCredentials = error else {
                return XCTFail("Expected .invalidCredentials, got \(error)")
            }
            XCTAssertEqual(mockRefresher.callCount, 1)
            XCTAssertTrue(authSession.requiresReauthentication)
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    // Revert-check: fails if saveTokens drops the ungated-save epoch bump
    // (`if epoch == nil { _cacheEpoch &+= 1 }`) that retires refreshes begun
    // under the previous credentials — the retired refresh's invalid_grant
    // verdict is then published into the replacement session, parking a
    // mailbox whose credentials are fine. Also fails (on the CancellationError
    // expectation, not the requiresReauthentication assert — the publish
    // helper's own epoch re-check still no-ops) if performTokenRefresh drops
    // the `guard cacheEpochMatches(epochAtStart)` at the head of its catch.
    func testRetiredRefreshCannotRequireReauthenticationForReplacementSession() async throws {
        let staleRefresher = ControlledFailingTokenRefresher(
            error: TokenManagerError.invalidCredentials
        )
        let manager = TokenManager(
            keychainService: mockKeychain,
            authSession: authSession,
            tokenRefresher: staleRefresher
        )
        authSession.isAuthenticated = true

        let staleRefresh = Task {
            try await manager.refreshToken()
        }
        await staleRefresher.waitUntilStarted()

        // A direct save establishes the replacement sign-in generation.
        try manager.saveTokens(
            access: "replacement-access",
            refresh: "replacement-refresh",
            expirationDate: Date().addingTimeInterval(3_600)
        )
        await staleRefresher.resumeWithFailure()

        do {
            _ = try await staleRefresh.value
            XCTFail("Expected the retired refresh to be cancelled")
        } catch is CancellationError {
            // Expected: a retired generation cannot return a usable token or
            // publish an authentication verdict into the replacement session.
        } catch {
            XCTFail("Expected CancellationError, got \(error)")
        }

        XCTAssertFalse(authSession.requiresReauthentication)
        XCTAssertTrue(authSession.canAccessMailbox)
        let currentToken = try await manager.getCurrentToken()
        XCTAssertEqual(currentToken, "replacement-access")
    }

    // Revert-check: fails if TokenRefreshCoordinator.getOrCreateTask stops
    // keying single-flight on `forGeneration:` (i.e. reverts to TaskCoordinator's
    // unconditional reuse of the live task). The replacement caller would join
    // the retired account's suspended refresh instead of issuing its own, so
    // waitUntilCallCount(2) times out at its 5s deadline and the assertions
    // below fail — the replacement inherits the retired task's
    // CancellationError rather than a usable token.
    func testReplacementGenerationDoesNotJoinRetiredRefreshTask() async throws {
        let refresher = ControlledFailingTokenRefresher(
            error: TokenManagerError.invalidCredentials,
            succeedingAccessToken: "replacement-refreshed-access"
        )
        let manager = TokenManager(
            keychainService: mockKeychain,
            authSession: authSession,
            tokenRefresher: refresher
        )
        authSession.isAuthenticated = true

        let staleRefresh = Task {
            try await manager.refreshToken()
        }
        await refresher.waitUntilStarted()
        try manager.saveTokens(
            access: "replacement-access",
            refresh: "replacement-refresh",
            expirationDate: Date().addingTimeInterval(3_600)
        )

        let replacementRefresh = Task {
            try await manager.refreshToken()
        }
        await refresher.waitUntilCallCount(2)
        let replacementToken = try await replacementRefresh.value
        XCTAssertEqual(replacementToken, "replacement-refreshed-access")

        await refresher.resumeWithFailure()
        do {
            _ = try await staleRefresh.value
            XCTFail("Expected the retired refresh to be cancelled")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Expected CancellationError, got \(error)")
        }

        XCTAssertFalse(authSession.requiresReauthentication)
        XCTAssertTrue(authSession.canAccessMailbox)
        let currentToken = try await manager.getCurrentToken()
        XCTAssertEqual(currentToken, "replacement-refreshed-access")
    }

    // Revert-check: fails if getOrCreateTask's `generation < latestGeneration`
    // early return (the throwaway cancelled handle) is removed. A caller that
    // snapshotted an old epoch and reached the actor late would then overwrite
    // currentEntry/latestGeneration, so the still-live newer generation loses
    // its single-flight entry — the reuse call gets a fresh id and runs the
    // "duplicate" factory instead of returning "replacement".
    func testRefreshCoordinatorRejectsDelayedRetiredGenerationWithoutEvictingNewTask() async throws {
        let coordinator = TokenRefreshCoordinator()
        let replacementHandle = await coordinator.getOrCreateTask(forGeneration: 2) {
            Task<String, Error> { "replacement" }
        }
        let retiredHandle = await coordinator.getOrCreateTask(forGeneration: 1) {
            Task<String, Error> { "retired" }
        }

        do {
            _ = try await retiredHandle.task.value
            XCTFail("Expected the delayed retired registration to be cancelled")
        } catch is CancellationError {
            // Expected.
        }

        let reusedReplacementHandle = await coordinator.getOrCreateTask(forGeneration: 2) {
            Task<String, Error> { "duplicate" }
        }
        XCTAssertEqual(reusedReplacementHandle.id, replacementHandle.id)
        let replacementToken = try await reusedReplacementHandle.task.value
        XCTAssertEqual(replacementToken, "replacement")
    }

    func testRefreshToken_noValidTokenError_doesNotRetry() async {
        authSession.isAuthenticated = true
        mockRefresher.errorToThrow = TokenManagerError.noValidToken

        do {
            _ = try await sut.refreshToken()
            XCTFail("Expected throw")
        } catch let error as TokenManagerError {
            guard case .noValidToken = error else {
                return XCTFail("Expected .noValidToken, got \(error)")
            }
            XCTAssertEqual(mockRefresher.callCount, 1, "Non-retryable errors should not retry")
            XCTAssertFalse(authSession.requiresReauthentication)
        } catch {
            XCTFail("Unexpected error type: \(error)")
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

private actor ControlledFailingTokenRefresher: TokenRefresherProtocol {
    private let error: Error
    private let succeedingAccessToken: String?
    private var callCount = 0
    private var didStart = false
    private var failureContinuation: CheckedContinuation<Void, Never>?

    init(error: Error, succeedingAccessToken: String? = nil) {
        self.error = error
        self.succeedingAccessToken = succeedingAccessToken
    }

    func refreshTokens() async throws -> (
        accessToken: String,
        refreshToken: String?,
        expirationDate: Date
    ) {
        callCount += 1
        let currentCall = callCount
        didStart = true

        if currentCall > 1, let succeedingAccessToken {
            return (
                accessToken: succeedingAccessToken,
                refreshToken: "replacement-refreshed-refresh",
                expirationDate: Date().addingTimeInterval(3_600)
            )
        }

        await withCheckedContinuation { continuation in
            failureContinuation = continuation
        }
        throw error
    }

    /// Deadline-bounded (house rule) so a regression fails the calling
    /// test's next assertion instead of hanging the whole suite.
    func waitUntilStarted() async {
        let deadline = Date().addingTimeInterval(5)
        while !didStart, Date() < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    func waitUntilCallCount(_ expectedCount: Int) async {
        let deadline = Date().addingTimeInterval(5)
        while callCount < expectedCount, Date() < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    func resumeWithFailure() {
        failureContinuation?.resume()
        failureContinuation = nil
    }
}
