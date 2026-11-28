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

    // MARK: - adoptTokens

    // Revert-check: fails if `adoptTokens(access:expirationDate:ifCacheEpochMatches:)`
    // writes the token to the keychain again, as `saveTokens` did at every
    // launch until 2026-11-28 (architecture review 2026-11, `account-boundary-auth#4`).
    func testAdoptTokens_writesNothingToTheKeychain() async throws {
        sut.adoptTokens(access: "access-1", expirationDate: Date().addingTimeInterval(3600))

        XCTAssertEqual(mockKeychain.saveCallCount, 0)
        XCTAssertFalse(LegacyTokenItems.anyStored(in: mockKeychain))
        let token = try await sut.getCurrentToken()
        XCTAssertEqual(token, "access-1", "The adopted token is the one requests are given")
        XCTAssertEqual(mockRefresher.callCount, 0)
    }

    // Revert-check: fails if the ungated `adoptTokens` stops calling
    // `removeLegacyTokenItemsIfNeeded()`: the items an earlier build wrote, the
    // refresh token's copy among them, would stay in the keychain until a sign-out.
    func testAdoptTokens_ungated_deletesTheItemsEarlierBuildsWrote() throws {
        try LegacyTokenItems.seed(in: mockKeychain)

        sut.adoptTokens(access: "access-1", expirationDate: Date().addingTimeInterval(3600))

        XCTAssertFalse(LegacyTokenItems.anyStored(in: mockKeychain))
    }

    // Revert-check: fails if `removeLegacyTokenItemsIfNeeded()` drops its
    // `_legacyTokenItemsRemoved` guard: every restore and sign-in in the
    // process would delete them again.
    func testAdoptTokens_ungatedTwice_deletesTheLegacyItemsOnce() {
        sut.adoptTokens(access: "a", expirationDate: Date().addingTimeInterval(3600))
        let deletesAfterFirst = mockKeychain.deleteCallCount
        sut.adoptTokens(access: "b", expirationDate: Date().addingTimeInterval(3600))

        XCTAssertEqual(deletesAfterFirst, 2)
        XCTAssertEqual(mockKeychain.deleteCallCount, 2, "The process deletes them once")
    }

    // Revert-check: fails if `removeLegacyTokenItemsIfNeeded()` sets
    // `_legacyTokenItemsRemoved` before its deletes have succeeded: a failed
    // delete would never be asked again in the process.
    func testAdoptTokens_legacyDeleteFails_adoptsTheTokenAndDeletesNextTime() async throws {
        struct DeleteFailure: Error {}
        try LegacyTokenItems.seed(in: mockKeychain)
        mockKeychain.failNextDelete(
            for: KeychainService.Key.googleAccessToken.rawValue,
            with: DeleteFailure()
        )

        sut.adoptTokens(access: "first", expirationDate: Date().addingTimeInterval(3600))

        XCTAssertTrue(LegacyTokenItems.anyStored(in: mockKeychain))
        let adopted = try await sut.getCurrentToken()
        XCTAssertEqual(adopted, "first", "A failed cleanup does not fail the adoption")

        sut.adoptTokens(access: "second", expirationDate: Date().addingTimeInterval(3600))

        XCTAssertFalse(LegacyTokenItems.anyStored(in: mockKeychain))
    }

    func testAdoptTokens_updatesInMemoryAuthSessionAccessToken() async throws {
        sut.adoptTokens(access: "memory-cached", expirationDate: Date().addingTimeInterval(3600))

        await waitForAccessToken("memory-cached")
        XCTAssertEqual(authSession.accessToken, "memory-cached")
    }

    // MARK: - clearTokens

    func testClearTokens_deletesTheItemsEarlierBuildsWrote() throws {
        try LegacyTokenItems.seed(in: mockKeychain)

        try sut.clearTokens()

        XCTAssertFalse(LegacyTokenItems.anyStored(in: mockKeychain))
    }

    func testClearTokens_clearsInMemoryAuthSessionAccessToken() async throws {
        authSession.accessToken = "cached"
        sut.adoptTokens(access: "cached", expirationDate: Date().addingTimeInterval(3600))
        await waitForAccessToken("cached")

        try sut.clearTokens()

        await waitForAccessToken(nil)
        XCTAssertNil(authSession.accessToken)
    }

    // MARK: - isAuthenticated

    func testIsAuthenticated_nothingAdopted_returnsFalse() {
        XCTAssertFalse(sut.isAuthenticated())
    }

    // Revert-check: fails if `isAuthenticated()` reads the access-token item
    // an earlier build wrote in place of the cache.
    func testIsAuthenticated_onlyAnEarlierBuildsItem_returnsFalse() throws {
        try LegacyTokenItems.seed(in: mockKeychain)

        XCTAssertFalse(sut.isAuthenticated())
    }

    func testIsAuthenticated_validToken_returnsTrue() throws {
        sut.adoptTokens(access: "a", expirationDate: Date().addingTimeInterval(3600))
        XCTAssertTrue(sut.isAuthenticated())
    }

    func testIsAuthenticated_expiredToken_returnsFalse() throws {
        sut.adoptTokens(access: "a", expirationDate: Date().addingTimeInterval(-60))
        XCTAssertFalse(sut.isAuthenticated())
    }

    // MARK: - getCurrentToken

    func testGetCurrentToken_adoptedToken_returnsItWithoutRefresh() async throws {
        sut.adoptTokens(access: "stored", expirationDate: Date().addingTimeInterval(3600))

        let token = try await sut.getCurrentToken()

        XCTAssertEqual(token, "stored")
        XCTAssertEqual(mockRefresher.callCount, 0)
    }

    func testGetCurrentToken_nothingAdopted_triggersRefresh() async throws {
        mockRefresher.accessToken = "fresh-after-refresh"
        mockRefresher.expirationDate = Date().addingTimeInterval(3600)

        let token = try await sut.getCurrentToken()

        XCTAssertEqual(token, "fresh-after-refresh")
        XCTAssertEqual(mockRefresher.callCount, 1)
    }

    // Revert-check: fails if `getCurrentToken` reads the access-token item an
    // earlier build wrote before it refreshes: a process that adopted nothing
    // would be handed a token GoogleSignIn did not give it.
    func testGetCurrentToken_nothingAdoptedBesideAnEarlierBuildsItem_refreshesWithoutReadingIt() async throws {
        try LegacyTokenItems.seed(in: mockKeychain, accessToken: "legacy-access")
        mockRefresher.accessToken = "from-google-sign-in"
        mockRefresher.expirationDate = Date().addingTimeInterval(3600)
        let loadsBefore = mockKeychain.loadCallCount

        let token = try await sut.getCurrentToken()

        XCTAssertEqual(token, "from-google-sign-in")
        XCTAssertEqual(mockRefresher.callCount, 1)
        XCTAssertEqual(mockKeychain.loadCallCount, loadsBefore, "No keychain read")
    }

    func testGetCurrentToken_expiringSoonToken_triggersRefresh() async throws {
        // Token expires in 1 minute — inside the 5-minute "expiring soon" window.
        sut.adoptTokens(access: "soon-expiring", expirationDate: Date().addingTimeInterval(60))

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

    func testRefreshToken_adoptsTheNewTokenAndWritesNothingToTheKeychain() async throws {
        mockRefresher.accessToken = "brand-new"
        mockRefresher.refreshToken = "new-refresh"
        mockRefresher.expirationDate = Date().addingTimeInterval(3600)

        _ = try await sut.refreshToken()

        XCTAssertEqual(mockKeychain.saveCallCount, 0)
        XCTAssertFalse(LegacyTokenItems.anyStored(in: mockKeychain))
        let current = try await sut.getCurrentToken()
        XCTAssertEqual(current, "brand-new")
        XCTAssertEqual(mockRefresher.callCount, 1, "The refreshed token is served from the cache")
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

    // Revert-check: fails if adoptTokens drops the ungated-adoption epoch bump
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

        // A direct adoption establishes the replacement sign-in generation.
        manager.adoptTokens(
            access: "replacement-access",
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
        manager.adoptTokens(
            access: "replacement-access",
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

    // MARK: - refreshToken(rejecting:) (architecture review 2026-11, gap-wall-clock-time#2)

    // Revert-check: fails if `TokenRefreshCoordinator.getOrCreateTask` loses
    // its `joinsOnlySamePurpose` term (the second look of
    // `refreshToken(rejecting:)` would join the `.freshToken` refresh that had
    // just handed the rejected token back), or stops letting a caller join an
    // entry started for another purpose (a burst of 401s would start one
    // refresh each).
    func testRefreshCoordinator_joinRules_shareAcrossPurposesUntilASecondLookAsksForTheSameOne() async throws {
        let coordinator = TokenRefreshCoordinator()
        let replacing = TokenRefreshPurpose.replacing(rejectedAccessToken: "rejected")

        let plain = await coordinator.getOrCreateTask(forGeneration: 1) {
            Task<String, Error> { "rejected" }
        }
        let firstLook = await coordinator.getOrCreateTask(forGeneration: 1, purpose: replacing) {
            Task<String, Error> { "unexpected" }
        }
        XCTAssertEqual(firstLook.id, plain.id, "A 401's first look joins the refresh in flight")
        XCTAssertEqual(firstLook.purpose, .freshToken)

        let secondLook = await coordinator.getOrCreateTask(
            forGeneration: 1,
            purpose: replacing,
            joinsOnlySamePurpose: true
        ) {
            Task<String, Error> { "forced" }
        }
        XCTAssertNotEqual(secondLook.id, plain.id, "The second look never joins a plain refresh")
        XCTAssertEqual(secondLook.purpose, replacing)
        let forced = try await secondLook.task.value
        XCTAssertEqual(forced, "forced")

        let anotherForcingCaller = await coordinator.getOrCreateTask(
            forGeneration: 1,
            purpose: replacing,
            joinsOnlySamePurpose: true
        ) {
            Task<String, Error> { "duplicate" }
        }
        XCTAssertEqual(anotherForcingCaller.id, secondLook.id, "Forcing callers for one token share one refresh")
        let plainCaller = await coordinator.getOrCreateTask(forGeneration: 1) {
            Task<String, Error> { "duplicate" }
        }
        XCTAssertEqual(plainCaller.id, secondLook.id, "A plain caller joins a forcing refresh")
    }

    // Revert-check: fails if `TokenManager.cachedReplacement(for:ifCacheEpochMatches:)`
    // stops answering with a cached token other than the rejected one: a 401
    // that arrives after another one's refresh already replaced the token
    // would ask Google again.
    // HONEST SCOPE: it is asked twice, by `refreshToken(rejecting:)` and again
    // as `performTokenRefresh` starts, and either call alone answers this, so
    // removing just one of them still passes.
    func testRefreshTokenRejecting_cacheHoldsAnotherFreshToken_returnsItWithoutRefreshing() async throws {
        sut.adoptTokens(access: "replacement", expirationDate: Date().addingTimeInterval(3_600))

        let token = try await sut.refreshToken(rejecting: "rejected")

        XCTAssertEqual(token, "replacement")
        XCTAssertEqual(mockRefresher.callCount, 0)
        XCTAssertEqual(mockRefresher.forcedCallCount, 0)
    }

    // Revert-check: fails if `performTokenRefresh`'s opening
    // `cachedReplacement(for:ifCacheEpochMatches:)` drops its `epochAtStart`:
    // a refresh whose generation a replacement sign-in retired would return
    // the replacement session's token instead of a `CancellationError`.
    func testPerformTokenRefreshRejecting_retiredGeneration_isCancelledNotHandedTheReplacementToken() async throws {
        let retiredEpoch = sut.cacheEpoch()
        sut.adoptTokens(
            access: "replacement-access",
            expirationDate: Date().addingTimeInterval(3_600)
        )

        do {
            let token = try await sut.performTokenRefresh(
                ifCacheEpochMatches: retiredEpoch,
                rejecting: "rejected"
            )
            XCTFail("Expected the retired refresh to be cancelled, got \(token)")
        } catch is CancellationError {
            // Expected.
        }
        XCTAssertEqual(mockRefresher.callCount, 0)
        XCTAssertEqual(mockRefresher.forcedCallCount, 0)
    }

    // Revert-check: fails if `TokenManager.refreshToken(rejecting:)` returns
    // what the refresh it joined returned without its second look (`guard
    // token == rejectedAccessToken, joined.purpose != purpose`): a 401 caller
    // that joins a plain refresh of the same stale token is handed that token.
    // HONEST SCOPE: the plain refresh is held open for 0.3 s for the 401 caller
    // to join it, which nothing outside the coordinator can confirm; a caller
    // that arrives late starts its own refresh and gets the same answer, so a
    // slow run can pass with the second look removed. The join rule itself is
    // pinned deterministically by the coordinator test above.
    func testRefreshTokenRejecting_joinsAPlainRefreshThatHandsBackTheRejectedToken_forcesANewOne() async throws {
        sut.adoptTokens(access: "rejected", expirationDate: Date().addingTimeInterval(3_600))
        mockRefresher.accessToken = "rejected"
        mockRefresher.forcedAccessToken = "forced"
        mockRefresher.artificialDelay = 0.3

        let manager = sut!
        let plainRefresh = Task { try await manager.refreshToken() }
        // The mock counts a call only after its delay, so the plain refresh's
        // start is read from `isRefreshing`, which its task sets first.
        let deadline = Date().addingTimeInterval(5)
        while !sut.isRefreshing, Date() < deadline {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        let rejecting = try await sut.refreshToken(rejecting: "rejected")
        let plain = try await plainRefresh.value

        XCTAssertEqual(plain, "rejected", "The plain refresh hands back what GoogleSignIn holds")
        XCTAssertEqual(rejecting, "forced", "The 401 caller is never handed the rejected token")
        XCTAssertEqual(mockRefresher.forcedCallCount, 1)
        let current = try await sut.getCurrentToken()
        XCTAssertEqual(current, "forced")
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

    // Revert-check: fails if `isRetryableError` moves
    // `.refreshedIDTokenRefused` to its retryable cases: a refusal by the
    // device's clock would cost three token requests.
    func testIsRetryableError_refreshedIDTokenRefused_isNotRetryable() {
        let underlying = NSError(domain: "org.openid.appauth.general", code: -15)
        XCTAssertFalse(sut.isRetryableError(TokenManagerError.refreshedIDTokenRefused(underlying)))
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

    /// Never asked for: these tests' refreshes reject no token.
    func forceRefreshTokens() async throws -> (
        accessToken: String,
        refreshToken: String?,
        expirationDate: Date
    ) {
        XCTFail("ControlledFailingTokenRefresher is not asked for a forced refresh")
        throw TokenManagerError.noValidToken
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
