import XCTest
@testable import esc_chatmail

/// A token manager whose preflight fails the same way every time, so a batch
/// of several IDs cannot slip a request past the failure (`MockTokenManager`
/// clears its error after one throw).
private final class AlwaysFailingTokenManager: TokenManagerProtocol, @unchecked Sendable {
    private let error: Error

    init(error: Error) {
        self.error = error
    }

    func getCurrentToken() async throws -> String { throw error }
    func refreshToken() async throws -> String { throw error }
    func saveTokens(access: String, refresh: String?, expirationDate: Date) throws {}
    func clearTokens() throws {}
    func isAuthenticated() -> Bool { true }
}

private actor PersistRecorder {
    private(set) var callCount = 0

    func record() {
        callCount += 1
    }
}

/// The token preflight ahead of every request (`authenticatedRequest`) fails
/// as an `APIError`, so a revoked or missing token is the account-scoped
/// abort the callers already handle, and never a raw `TokenManagerError`
/// (architecture review 2026-11, `networking#3`). Run against the real
/// `GmailAPIClient` through `StubURLProtocol`: `MockGmailAPIClient` replaces
/// the preflight itself, so a mock-based test here would prove nothing.
final class GmailAPIClientTokenPreflightTests: XCTestCase {

    private var tokenManager: MockTokenManager!
    private var client: GmailAPIClient!

    override func setUp() {
        super.setUp()
        StubURLProtocol.reset()
        tokenManager = MockTokenManager()
        client = makeClient(tokenManager: tokenManager)
    }

    override func tearDown() {
        StubURLProtocol.reset()
        client = nil
        tokenManager = nil
        super.tearDown()
    }

    private func makeClient(tokenManager: any TokenManagerProtocol) -> GmailAPIClient {
        GmailAPIClient(
            tokenManager: tokenManager,
            retryStrategy: NetworkRetryStrategy(maxRetries: 3, initialDelay: 0.01, maxDelay: 0.02),
            session: StubURLProtocol.makeSession()
        )
    }

    private struct SomeOtherError: Error {}

    // MARK: - The mapper

    // Revert-check: fails if `GmailAPIClient.apiError(forTokenAcquisitionFailure:)`
    // stops mapping `invalidCredentials` to `.credentialsRevoked`.
    func testMapper_invalidCredentials_isCredentialsRevoked() {
        let mapped = GmailAPIClient.apiError(forTokenAcquisitionFailure: TokenManagerError.invalidCredentials)

        guard case .credentialsRevoked? = mapped as? APIError else {
            return XCTFail("Expected credentialsRevoked, got \(mapped)")
        }
    }

    // Revert-check: fails if the mapper maps any other token error to
    // `.credentialsRevoked` (which would park the queue with nothing asking the
    // user to sign in again), to `.networkError` (which `MessageFetcher`
    // retries), or lets it through raw.
    func testMapper_everyOtherTokenError_isAuthenticationError() {
        let others: [TokenManagerError] = [
            .noValidToken,
            .refreshFailed(SomeOtherError()),
            .networkUnavailable,
            .rateLimitExceeded,
            .tokenExpired
        ]

        for tokenError in others {
            let mapped = GmailAPIClient.apiError(forTokenAcquisitionFailure: tokenError)
            guard case .authenticationError? = mapped as? APIError else {
                return XCTFail("Expected authenticationError for \(tokenError), got \(mapped)")
            }
        }
    }

    // Revert-check: fails if the mapper stops passing a raw error through as
    // `.authenticationError`: an unknown failure of the preflight is still no
    // verdict on the message or action being processed.
    func testMapper_rawError_isAuthenticationError() {
        let raw = NSError(domain: "test", code: 7)

        let mapped = GmailAPIClient.apiError(forTokenAcquisitionFailure: raw)

        guard case .authenticationError? = mapped as? APIError else {
            return XCTFail("Expected authenticationError, got \(mapped)")
        }
    }

    // Revert-check: fails if the mapper turns a `CancellationError` into an
    // `APIError`. `TokenManager` throws it for a refresh whose epoch a sign-out
    // retired; as an `APIError` the teardown's cancellation would be recorded
    // as an account-scoped verdict, and a send's pre-barrier cancellation
    // would stop rolling back.
    func testMapper_cancellation_passesThrough() {
        let mapped = GmailAPIClient.apiError(forTokenAcquisitionFailure: CancellationError())

        XCTAssertTrue(mapped is CancellationError, "\(mapped)")
    }

    // Revert-check: fails if the mapper re-maps an `APIError`, which is
    // already classified.
    func testMapper_apiError_passesThrough() {
        let mapped = GmailAPIClient.apiError(forTokenAcquisitionFailure: APIError.quotaExhausted("daily"))

        guard case .quotaExhausted? = mapped as? APIError else {
            return XCTFail("Expected the APIError unchanged, got \(mapped)")
        }
    }

    // MARK: - The real client

    // Revert-check: fails if `authenticatedRequest` stops routing the
    // preflight's error through the mapper: the raw `TokenManagerError` comes
    // out, and `MessageFetcher` would bucket the ID as permanently failed.
    func testGetMessage_preflightInvalidCredentials_throwsCredentialsRevokedAndSendsNothing() async {
        tokenManager.getTokenError = TokenManagerError.invalidCredentials

        do {
            _ = try await client.getMessage(id: "m1", format: "full", maxRetries: 1)
            XCTFail("Expected credentialsRevoked")
        } catch APIError.credentialsRevoked {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertEqual(StubURLProtocol.requestCount, 0, "Nothing is sent without a token")
    }

    // Revert-check: fails with the raw `noValidToken` (the error a held
    // account's refresher throws) if the catch in `authenticatedRequest` goes.
    func testGetMessage_preflightNoValidToken_throwsAuthenticationErrorAndSendsNothing() async {
        tokenManager.getTokenError = TokenManagerError.noValidToken

        do {
            _ = try await client.getMessage(id: "m1", format: "full", maxRetries: 1)
            XCTFail("Expected authenticationError")
        } catch APIError.authenticationError {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertEqual(StubURLProtocol.requestCount, 0)
        XCTAssertEqual(tokenManager.refreshTokenCallCount, 0, "The preflight's own refresh already ran inside TokenManager")
    }

    // Revert-check: fails if a cancelled preflight is reported as an
    // `APIError` (the mapper's pass-through) or swallowed.
    func testGetMessage_preflightCancellation_throwsCancellationError() async {
        tokenManager.getTokenError = CancellationError()

        do {
            _ = try await client.getMessage(id: "m1", format: "full", maxRetries: 1)
            XCTFail("Expected CancellationError")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertEqual(StubURLProtocol.requestCount, 0)
    }

    // Revert-check: fails if the preflight's failure stops being an
    // `APIError`: a send's pre-barrier failure would carry the raw token
    // error, which the send service rethrows to the orchestrator unclassified.
    func testSendMessage_preflightInvalidCredentials_isNotStartedWithCredentialsRevoked() async {
        tokenManager.getTokenError = TokenManagerError.invalidCredentials

        do {
            _ = try await client.sendMessage(mimeData: Data("raw".utf8))
            XCTFail("Expected a pre-transmission failure")
        } catch GmailMessageSendError.transmissionNotStarted(let underlying) {
            guard case .credentialsRevoked? = underlying as? APIError else {
                return XCTFail("Expected credentialsRevoked before the barrier, got \(underlying)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertEqual(StubURLProtocol.requestCount, 0)
    }

    // MARK: - MessageFetcher: a run abort, not per-message verdicts

    // Revert-check: fails if the mapper or the catch in `authenticatedRequest`
    // goes: `fetchBatch` then returns an outcome with every ID in
    // `blockingFailureIds` (a raw `TokenManagerError` is not retriable and not
    // account-scoped, so `fetchWithBoundedConcurrency` buckets it as
    // permanently failed), and the sync run stages three deferred rows and an
    // escape-hatch strike for a revoked token.
    func testFetchBatch_preflightInvalidCredentials_abortsTheRunWithNoVerdictAndNoRequest() async {
        let failing = AlwaysFailingTokenManager(error: TokenManagerError.invalidCredentials)
        let fetcher = MessageFetcher(apiClient: makeClient(tokenManager: failing))
        let recorder = PersistRecorder()

        do {
            _ = try await fetcher.fetchBatch(["m1", "m2", "m3"]) { _ in
                await recorder.record()
                return .empty
            }
            XCTFail("Expected the account-scoped abort to throw")
        } catch APIError.credentialsRevoked {
            // Expected: the run aborts and nothing commits.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        let persistCalls = await recorder.callCount
        XCTAssertEqual(persistCalls, 0)
        XCTAssertEqual(StubURLProtocol.requestCount, 0)
    }

    // Revert-check: as above, for the error a held account's refresher throws
    // when there is no SDK user (`noValidToken`): it must be an abort, not a
    // permanent failure for every message of the batch.
    func testFetchBatch_preflightNoValidToken_abortsTheRunWithAuthenticationError() async {
        let failing = AlwaysFailingTokenManager(error: TokenManagerError.noValidToken)
        let fetcher = MessageFetcher(apiClient: makeClient(tokenManager: failing))

        do {
            _ = try await fetcher.fetchBatch(["m1", "m2"]) { _ in .empty }
            XCTFail("Expected the account-scoped abort to throw")
        } catch APIError.authenticationError {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertEqual(StubURLProtocol.requestCount, 0)
    }
}
