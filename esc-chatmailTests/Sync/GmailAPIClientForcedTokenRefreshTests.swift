import XCTest
@testable import esc_chatmail

/// Forwards to the real `TokenManager` and counts the 401 path's calls, so a
/// test can hold a refresh open until every caller has reached it.
private final class CountingTokenManager: TokenManagerProtocol, @unchecked Sendable {
    private let base: TokenManager
    /// Guards `_rejectingCallCount`; the client calls from many tasks at once.
    private let lock = NSLock()
    private var _rejectingCallCount = 0

    init(base: TokenManager) {
        self.base = base
    }

    var rejectingCallCount: Int {
        lock.withLock { _rejectingCallCount }
    }

    func getCurrentToken() async throws -> String { try await base.getCurrentToken() }
    func refreshToken() async throws -> String { try await base.refreshToken() }

    func refreshToken(rejecting rejectedAccessToken: String) async throws -> String {
        lock.withLock { _rejectingCallCount += 1 }
        return try await base.refreshToken(rejecting: rejectedAccessToken)
    }

    func adoptTokens(access: String, expirationDate: Date) {
        base.adoptTokens(access: access, expirationDate: expirationDate)
    }

    func clearTokens() throws { try base.clearTokens() }
    func isAuthenticated() -> Bool { base.isAuthenticated() }
}

/// GoogleSignIn's side of a forced refresh as `GoogleTokenRefresher` drives it,
/// through `GoogleForcedTokenRefresh`, over a stand-in for the user's auth
/// state: a send that fails leaves the old token in place, as AppAuth does
/// after a network error. The plain refresh hands back the held token, as
/// `refreshTokensIfNeeded` does by a clock set back.
private final class SteppedForcedRefresher: TokenRefresherProtocol, @unchecked Sendable {
    /// Guards every stored property; the refresh runs off the test's actor.
    private let lock = NSLock()
    private var heldAccessToken: String
    private let refreshedAccessToken: String
    /// One entry per send, in order: an error, or nil for a send that
    /// succeeds. Sends past the end succeed.
    private var sendOutcomes: [Error?]
    private var _sendCount = 0

    init(heldAccessToken: String, refreshedAccessToken: String, sendOutcomes: [Error?]) {
        self.heldAccessToken = heldAccessToken
        self.refreshedAccessToken = refreshedAccessToken
        self.sendOutcomes = sendOutcomes
    }

    var sendCount: Int {
        lock.withLock { _sendCount }
    }

    private var heldTokens: GoogleForcedTokenRefresh.Tokens {
        lock.withLock {
            (accessToken: heldAccessToken, refreshToken: "refresh-token", expirationDate: Date().addingTimeInterval(3_600))
        }
    }

    private func answerSend() -> Error? {
        lock.withLock {
            _sendCount += 1
            let outcome = sendOutcomes.isEmpty ? nil : sendOutcomes.removeFirst()
            if outcome == nil {
                heldAccessToken = refreshedAccessToken
            }
            return outcome
        }
    }

    func refreshTokens() async throws -> (accessToken: String, refreshToken: String?, expirationDate: Date) {
        heldTokens
    }

    func forceRefreshTokens() async throws -> (accessToken: String, refreshToken: String?, expirationDate: Date) {
        try await Self.runForcedRefresh(on: self)
    }

    @MainActor
    private static func runForcedRefresh(on refresher: SteppedForcedRefresher) async throws -> GoogleForcedTokenRefresh.Tokens {
        try await GoogleForcedTokenRefresh(
            send: { completion in completion(refresher.answerSend()) },
            readTokens: { refresher.heldTokens }
        ).run()
    }
}

/// The 401 path against the real `TokenManager`, through the real
/// `GmailAPIClient` and `StubURLProtocol` (architecture review 2026-11,
/// `gap-wall-clock-time#2`). GoogleSignIn's refresh asks Google only by the
/// device's clock, so with the clock set back it handed back the token Gmail
/// had just rejected, and every request drew two 401s and failed as
/// `authenticationError`. `MockTokenRefresher` stands in for GoogleSignIn:
/// its plain refresh is `refreshTokensIfNeeded`, its forced one
/// `forceRefreshTokens()`. A `MockTokenManager` here would prove nothing: the
/// comparison under test is `TokenManager`'s.
@MainActor
final class GmailAPIClientForcedTokenRefreshTests: XCTestCase {

    private nonisolated static let rejectedToken = "rejected-access-token"
    private nonisolated static let forcedToken = "forced-access-token"
    private nonisolated static let messageBody = Data(#"{"id":"m1","threadId":"t1"}"#.utf8)
    private nonisolated static let sendBody = Data(#"{"id":"sent-1","threadId":"thread-1"}"#.utf8)

    private var keychain: MockKeychainService!
    private var refresher: MockTokenRefresher!
    private var authSession: AuthSession!
    private var tokenManager: TokenManager!

    override func setUp() async throws {
        try await super.setUp()
        StubURLProtocol.reset()
        keychain = MockKeychainService()
        refresher = MockTokenRefresher()
        let placeholderTokenManager = MockTokenManager()
        authSession = AuthSession(
            tokenManagerProvider: { placeholderTokenManager },
            keychainService: keychain,
            userDefaults: UserDefaults(suiteName: "GmailAPIClientForcedTokenRefreshTests-\(UUID().uuidString)")!,
            clearConversationCaches: {},
            cleanupDownloads: {},
            resetCoreDataStore: {},
            clearAttachmentCache: {}
        )
        tokenManager = TokenManager(
            keychainService: keychain,
            authSession: authSession,
            tokenRefresher: refresher
        )

        // The token Gmail will reject, held as fresh by the device's clock
        // (a clock set back), and what GoogleSignIn's plain refresh hands back.
        tokenManager.adoptTokens(
            access: Self.rejectedToken,
            expirationDate: Date().addingTimeInterval(3_600)
        )
        refresher.accessToken = Self.rejectedToken
        refresher.forcedAccessToken = Self.forcedToken
        refresher.expirationDate = Date().addingTimeInterval(3_600)
    }

    override func tearDown() async throws {
        StubURLProtocol.reset()
        tokenManager = nil
        authSession = nil
        refresher = nil
        keychain = nil
        try await super.tearDown()
    }

    private func makeClient(tokenManager: any TokenManagerProtocol) -> GmailAPIClient {
        GmailAPIClient(
            tokenManager: tokenManager,
            retryStrategy: NetworkRetryStrategy(maxRetries: 3, initialDelay: 0.01, maxDelay: 0.02),
            session: StubURLProtocol.makeSession()
        )
    }

    private static func bearers(of requests: [URLRequest]) -> [String?] {
        requests.map { GmailAPIClient.bearerToken(of: $0) }
    }

    /// Bounded by a wall-clock deadline (house rule): a regression fails the
    /// test's assertions instead of hanging the suite.
    private nonisolated static func waitUntil(
        timeout: TimeInterval = 5,
        pollIntervalNanoseconds: UInt64 = 10_000_000,
        _ condition: @Sendable () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            try? await Task.sleep(nanoseconds: pollIntervalNanoseconds)
        }
    }

    // MARK: - One forced refresh, then the new bearer

    // Revert-check: fails if `TokenManager.performTokenRefresh` loses its
    // `tokens.accessToken == rejectedAccessToken` comparison (the refresh
    // keeps GoogleSignIn's answer, the rejected token, and the client sends
    // nothing more), or if `TokenManager.cachedReplacement(for:)` loses its
    // `cached.accessToken != rejectedAccessToken` term (the cache answers with
    // the rejected token before any refresh). Either way one request goes out,
    // not two, and the call fails as `authenticationError`.
    func testGetMessage_401OnATokenGoogleSignInStillHolds_forcesOneRefreshAndResendsWithTheNewBearer() async throws {
        StubURLProtocol.script = [.status(401), .data(200, Self.messageBody)]
        let client = makeClient(tokenManager: tokenManager)

        let message = try await client.getMessage(id: "m1")

        XCTAssertEqual(message.id, "m1")
        XCTAssertEqual(StubURLProtocol.requestCount, 2)
        XCTAssertEqual(
            Self.bearers(of: StubURLProtocol.requests),
            [Self.rejectedToken, Self.forcedToken],
            "The resend carries the forced token, never the rejected one again"
        )
        XCTAssertEqual(refresher.callCount, 1, "GoogleSignIn's own refresh is asked first")
        XCTAssertEqual(refresher.forcedCallCount, 1, "Exactly one forced refresh")
        let current = try await tokenManager.getCurrentToken()
        XCTAssertEqual(current, Self.forcedToken)
        XCTAssertEqual(refresher.callCount, 1, "The forced token was adopted: asking again refreshes nothing")
    }

    // Revert-check: fails if `performTokenRefresh` forces a refresh whenever
    // it is given a rejected token, without first comparing GoogleSignIn's
    // answer with it: a 401 GoogleSignIn's own refresh already answers (its
    // clock says the token is expiring) would cost a second token request.
    func testGetMessage_401AndGoogleSignInRefreshesByItsOwnClock_forcesNothing() async throws {
        refresher.accessToken = "refreshed-by-google-sign-in"
        StubURLProtocol.script = [.status(401), .data(200, Self.messageBody)]
        let client = makeClient(tokenManager: tokenManager)

        _ = try await client.getMessage(id: "m1")

        XCTAssertEqual(
            Self.bearers(of: StubURLProtocol.requests),
            [Self.rejectedToken, "refreshed-by-google-sign-in"]
        )
        XCTAssertEqual(refresher.callCount, 1)
        XCTAssertEqual(refresher.forcedCallCount, 0)
    }

    // Revert-check: fails if `GmailAPIClient.performRetryingRequest`'s 401
    // branch loses its `guard newToken != rejectedToken`: the request would be
    // sent a second time with the token Gmail had just refused.
    func testGetMessage_forcedRefreshHandsBackTheRejectedToken_failsWithoutResending() async {
        refresher.forcedAccessToken = Self.rejectedToken
        StubURLProtocol.script = [.status(401), .data(200, Self.messageBody)]
        let client = makeClient(tokenManager: tokenManager)

        do {
            _ = try await client.getMessage(id: "m1")
            XCTFail("Expected authenticationError")
        } catch let error as APIError {
            guard case .authenticationError = error else {
                return XCTFail("Expected authenticationError, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertEqual(StubURLProtocol.requestCount, 1, "The rejected token is not sent again")
        XCTAssertEqual(refresher.forcedCallCount, 1)
    }

    // Revert-check: fails if `GoogleForcedTokenRefresh.run` reads the user's
    // tokens after a failed send (GTMAppAuth's `authorizeRequest` kept the
    // token and dropped the error): the first forced refresh would hand back
    // the rejected token as a success, nothing would retry it, and the call
    // would fail as `authenticationError` after one request.
    func testGetMessage_forcedRefreshFailsOnceInTransport_isRetriedAndResendsWithTheNewBearer() async throws {
        let stepped = SteppedForcedRefresher(
            heldAccessToken: Self.rejectedToken,
            refreshedAccessToken: Self.forcedToken,
            sendOutcomes: [NSError(
                domain: "org.openid.appauth.general",
                code: -5,
                userInfo: [NSUnderlyingErrorKey: URLError(.networkConnectionLost)]
            )]
        )
        let manager = TokenManager(keychainService: keychain, authSession: authSession, tokenRefresher: stepped)
        manager.adoptTokens(
            access: Self.rejectedToken,
            expirationDate: Date().addingTimeInterval(3_600)
        )
        StubURLProtocol.script = [.status(401), .data(200, Self.messageBody)]
        let client = makeClient(tokenManager: manager)

        let message = try await client.getMessage(id: "m1")

        XCTAssertEqual(message.id, "m1")
        XCTAssertEqual(
            Self.bearers(of: StubURLProtocol.requests),
            [Self.rejectedToken, Self.forcedToken]
        )
        XCTAssertEqual(stepped.sendCount, 2, "The transport failure is retried, once")
    }

    // Revert-check: fails if `GoogleTokenRefreshFailure.error(for:)` maps
    // AppAuth's -15 to `refreshFailed`: `TokenManager` would retry it,
    // and the 401 would cost three token requests instead of one.
    // HONEST SCOPE: the forced refresh helps only while the device's clock is
    // less than about ten minutes off; past that this is the outcome, the
    // same `authenticationError` as before the forced refresh existed.
    func testGetMessage_forcedRefreshRefusedForTheDeviceClock_costsOneTokenRequestAndKeepsTheCredentials() async throws {
        authSession.isAuthenticated = true
        let skewRefusal = NSError(
            domain: "org.openid.appauth.general",
            code: -15,
            userInfo: [NSLocalizedDescriptionKey: "Issued at time is more than 600 seconds before or after the current time"]
        )
        let stepped = SteppedForcedRefresher(
            heldAccessToken: Self.rejectedToken,
            refreshedAccessToken: Self.forcedToken,
            sendOutcomes: [skewRefusal, skewRefusal, skewRefusal]
        )
        let manager = TokenManager(keychainService: keychain, authSession: authSession, tokenRefresher: stepped)
        manager.adoptTokens(
            access: Self.rejectedToken,
            expirationDate: Date().addingTimeInterval(3_600)
        )
        StubURLProtocol.script = [.status(401), .data(200, Self.messageBody)]
        let client = makeClient(tokenManager: manager)

        do {
            _ = try await client.getMessage(id: "m1")
            XCTFail("Expected authenticationError")
        } catch let error as APIError {
            guard case .authenticationError = error else {
                return XCTFail("Expected authenticationError, never credentialsRevoked; got \(error)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertEqual(stepped.sendCount, 1, "One token request: the refusal is not retried")
        XCTAssertEqual(StubURLProtocol.requestCount, 1)
        XCTAssertFalse(authSession.requiresReauthentication, "Nobody is asked to sign in again")
        XCTAssertTrue(authSession.canAccessMailbox)
        let kept = try await manager.getCurrentToken()
        XCTAssertEqual(kept, Self.rejectedToken, "The credentials are kept")
        XCTAssertEqual(stepped.sendCount, 1, "The kept token is served from the cache, with no further request")
    }

    // Revert-check: fails if `GoogleTokenRefresher.refreshTokens()` wraps
    // GoogleSignIn's error as `refreshFailed` again instead of asking
    // `GoogleTokenRefreshFailure.error(for:)`, or if
    // `TokenManager.isRetryableError` counts `.refreshedIDTokenRefused` as
    // retryable (three token requests either way, the preflight's cost before
    // this change), or if `GmailAPIClient.apiError(forTokenAcquisitionFailure:)`
    // maps it to `credentialsRevoked` (the user asked to sign in again over a
    // clock).
    // HONEST SCOPE: the real `GoogleTokenRefresher` asks a `StubGoogleUser`,
    // whose `refreshTokensIfNeeded` answers with AppAuth's -15 in place of
    // GoogleSignIn's own, which makes the token request. That GoogleSignIn
    // hands the -15 on unchanged was read from its source, not run.
    func testGetMessage_plainRefreshRefusedForTheDeviceClock_costsOneTokenRequestAndSendsNothing() async throws {
        authSession.isAuthenticated = true
        let user = StubGoogleUser(
            email: "user@example.com",
            refreshError: NSError(
                domain: "org.openid.appauth.general",
                code: -15,
                userInfo: [NSLocalizedDescriptionKey: "Issued at time is more than 600 seconds before or after the current time"]
            )
        )
        authSession.currentUser = user
        let manager = TokenManager(
            keychainService: keychain,
            authSession: authSession,
            tokenRefresher: GoogleTokenRefresher(authSession: authSession)
        )
        // A clock set ahead past the token's expiry: `TokenManager` reads the
        // token as expired, and so does GoogleSignIn, which asks Google.
        manager.adoptTokens(
            access: Self.rejectedToken,
            expirationDate: Date().addingTimeInterval(-60)
        )
        let generation = manager.cacheEpoch()
        StubURLProtocol.script = [.data(200, Self.messageBody)]
        let client = makeClient(tokenManager: manager)

        do {
            _ = try await client.getMessage(id: "m1")
            XCTFail("Expected authenticationError")
        } catch let error as APIError {
            guard case .authenticationError = error else {
                return XCTFail("Expected authenticationError, never credentialsRevoked; got \(error)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertEqual(user.refreshCallCount, 1, "One token request: the refusal is not retried")
        XCTAssertEqual(StubURLProtocol.requestCount, 0, "No request is sent without a token")
        XCTAssertFalse(authSession.requiresReauthentication, "Nobody is asked to sign in again")
        XCTAssertTrue(authSession.canAccessMailbox)
        XCTAssertEqual(
            manager.cacheEpoch(),
            generation,
            "The credentials are kept: nothing cleared the tokens or retired the sign-in"
        )
    }

    // MARK: - Concurrent 401s on one token

    // Revert-check: fails if `TokenRefreshCoordinator.getOrCreateTask` stops
    // letting a caller join the generation's entry (`!joinsOnlySamePurpose ||
    // currentEntry.handle.purpose == purpose` made false): each 401 starts its
    // own refresh while the first is held, and each forces one.
    // HONEST SCOPE: the forced refresh is held until every caller has entered
    // `refreshToken(rejecting:)`, not until each has reached the coordinator,
    // which nothing outside it can see; the coordinator's own join rules are
    // pinned in `TokenManagerTests`.
    func testConcurrentGetMessages_401OnOneToken_shareOneForcedRefresh() async throws {
        let callerCount = 5
        let counting = CountingTokenManager(base: tokenManager)
        refresher.forcedRefreshGate = {
            await Self.waitUntil { counting.rejectingCallCount >= callerCount }
        }
        StubURLProtocol.responder = { request in
            GmailAPIClient.bearerToken(of: request) == Self.forcedToken
                ? .data(200, Self.messageBody)
                : .status(401)
        }
        let client = makeClient(tokenManager: counting)

        let ids = try await withThrowingTaskGroup(of: String.self) { group in
            for _ in 0..<callerCount {
                group.addTask { try await client.getMessage(id: "m1").id }
            }
            var ids: [String] = []
            for try await id in group {
                ids.append(id)
            }
            return ids
        }

        XCTAssertEqual(ids, Array(repeating: "m1", count: callerCount))
        XCTAssertEqual(counting.rejectingCallCount, callerCount)
        XCTAssertEqual(refresher.forcedCallCount, 1, "One token request for the whole burst")
        XCTAssertEqual(refresher.callCount, 1)
        let bearers = Self.bearers(of: StubURLProtocol.requests)
        XCTAssertEqual(bearers.filter { $0 == Self.rejectedToken }.count, callerCount)
        XCTAssertEqual(bearers.filter { $0 == Self.forcedToken }.count, callerCount)
    }

    // MARK: - Sign-out during the forced refresh

    // Revert-check: fails if `performTokenRefresh` adopts its token ungated
    // (`ifCacheEpochMatches: nil` in place of `epochAtStart`): the forced
    // token would be adopted for the signed-out account and the request sent
    // again with it.
    func testGetMessage_signOutDuringTheForcedRefresh_adoptsNothingAndSendsNothingMore() async throws {
        let manager = tokenManager!
        refresher.onForcedRefresh = {
            try? manager.clearTokens()
        }
        StubURLProtocol.script = [.status(401), .data(200, Self.messageBody)]
        let client = makeClient(tokenManager: tokenManager)

        do {
            _ = try await client.getMessage(id: "m1")
            XCTFail("Expected authenticationError")
        } catch let error as APIError {
            guard case .authenticationError = error else {
                return XCTFail("Expected authenticationError, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertEqual(StubURLProtocol.requestCount, 1)
        XCTAssertEqual(refresher.forcedCallCount, 1)
        XCTAssertFalse(
            tokenManager.isAuthenticated(),
            "The forced token of a retired generation is never adopted"
        )
        let deadline = Date().addingTimeInterval(5)
        while authSession.accessToken != nil, Date() < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertNil(authSession.accessToken, "Nothing publishes the forced token after the sign-out")
    }

    // MARK: - A revoked grant found by the forced refresh

    // Revert-check: fails if `performTokenRefresh` stops sending the forced
    // refresh's errors through its own catch (an invalid_grant would leave as
    // a generic refresh failure, `authenticationError`, with nobody asked to
    // sign in again), or if the 401 branch's `catch
    // TokenManagerError.invalidCredentials` is removed.
    func testGetMessage_forcedRefreshFindsTheGrantRevoked_failsAsCredentialsRevoked() async {
        authSession.isAuthenticated = true
        refresher.forcedErrorToThrow = TokenManagerError.refreshFailed(NSError(
            domain: "org.openid.appauth.oauth_token",
            code: -10,
            userInfo: ["OIDOAuthErrorResponseErrorKey": ["error": "invalid_grant"]]
        ))
        StubURLProtocol.script = [.status(401), .data(200, Self.messageBody)]
        let client = makeClient(tokenManager: tokenManager)

        do {
            _ = try await client.getMessage(id: "m1")
            XCTFail("Expected credentialsRevoked")
        } catch let error as APIError {
            guard case .credentialsRevoked = error else {
                return XCTFail("Expected credentialsRevoked, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertEqual(StubURLProtocol.requestCount, 1)
        XCTAssertEqual(refresher.forcedCallCount, 1, "A revoked grant is not retried")
        XCTAssertTrue(authSession.requiresReauthentication)
    }

    // MARK: - messages.send keeps its one refresh-and-resend round

    // Revert-check: fails, as the read's test does, if `performTokenRefresh`
    // loses its `tokens.accessToken == rejectedAccessToken` comparison: the
    // send would get the rejected token back, go out once, and fail as
    // `authenticationError`.
    func testSendMessage_401OnATokenGoogleSignInStillHolds_resendsOnceWithTheForcedToken() async throws {
        StubURLProtocol.script = [.status(401), .data(200, Self.sendBody)]
        let client = makeClient(tokenManager: tokenManager)

        let response = try await client.sendMessage(mimeData: Data("raw".utf8))

        XCTAssertEqual(response.id, "sent-1")
        XCTAssertEqual(
            Self.bearers(of: StubURLProtocol.requests),
            [Self.rejectedToken, Self.forcedToken]
        )
        XCTAssertEqual(refresher.forcedCallCount, 1)
    }

    // Revert-check: fails if the 401 branch's `hasAttemptedTokenRefresh`
    // once-only bound is dropped: a second 401 would refresh again and send
    // messages.send a third time.
    func testSendMessage_401AgainAfterTheForcedToken_failsWithoutASecondRound() async {
        StubURLProtocol.script = [.status(401)]
        let client = makeClient(tokenManager: tokenManager)

        do {
            _ = try await client.sendMessage(mimeData: Data("raw".utf8))
            XCTFail("Expected authenticationError")
        } catch GmailMessageSendError.ambiguousDelivery(let underlying) {
            XCTFail("A 401 proves Gmail refused the send; it must not be ambiguous: \(underlying)")
        } catch let error as APIError {
            guard case .authenticationError = error else {
                return XCTFail("Expected authenticationError, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertEqual(StubURLProtocol.requestCount, 2, "One resend after the refresh, never a second round")
        XCTAssertEqual(refresher.forcedCallCount, 1)
    }
}
