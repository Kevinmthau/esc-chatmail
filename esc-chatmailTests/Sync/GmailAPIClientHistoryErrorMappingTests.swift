import XCTest
@testable import esc_chatmail

/// URLProtocol-level tests for the history retry loop's error mapping —
/// mock-based tests prove nothing about retry/mapping semantics because they
/// replace the whole client.
final class GmailAPIClientHistoryErrorMappingTests: XCTestCase {

    private var tokenManager: MockTokenManager!
    private var client: GmailAPIClient!

    override func setUp() {
        super.setUp()
        StubURLProtocol.reset()
        tokenManager = MockTokenManager()
        client = GmailAPIClient(
            tokenManager: tokenManager,
            retryStrategy: NetworkRetryStrategy(maxRetries: 3, initialDelay: 0.01, maxDelay: 0.02),
            session: StubURLProtocol.makeSession()
        )
    }

    override func tearDown() {
        StubURLProtocol.reset()
        client = nil
        tokenManager = nil
        super.tearDown()
    }

    private static let historyResponseBody = Data(#"{"historyId":"99"}"#.utf8)

    // MARK: - Unified 429 semantics (CX4)

    func testHistoryFinalAttempt429_carriesRetryAfterWithoutSleepingOrRecordingBackoff() async {
        // CX4 decision: the history path adopts the message path's 429
        // semantics — the capped Retry-After rides on the thrown error, and
        // backoff is recorded only for delays actually slept (History
        // previously recorded before its breaker checks and threw
        // rateLimited(retryAfter: nil)).
        StubURLProtocol.script = [
            .dataWithHeaders(429, Data(), ["Retry-After": "7"])
        ]
        let singleAttemptClient = GmailAPIClient(
            tokenManager: tokenManager,
            retryStrategy: NetworkRetryStrategy(maxRetries: 1, initialDelay: 0.01, maxDelay: 0.02),
            session: StubURLProtocol.makeSession()
        )

        let start = Date()
        do {
            _ = try await singleAttemptClient.listHistory(startHistoryId: "1")
            XCTFail("Expected rateLimited")
        } catch let APIError.rateLimited(retryAfter) {
            XCTAssertEqual(retryAfter, 7)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertLessThan(Date().timeIntervalSince(start), 2.0)
        let recorded = await singleAttemptClient.rateLimitTracker.currentCumulativeBackoff
        XCTAssertEqual(recorded, 0, accuracy: 0.001)
    }

    // MARK: - Revoked credentials during 401 recovery

    func testHistory401_refreshRevoked_mapsToCredentialsRevoked() async {
        StubURLProtocol.script = [.status(401)]
        tokenManager.refreshError = TokenManagerError.invalidCredentials

        do {
            _ = try await client.listHistory(startHistoryId: "1")
            XCTFail("Expected credentialsRevoked")
        } catch let error as APIError {
            guard case .credentialsRevoked = error else {
                return XCTFail("Expected credentialsRevoked, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testHistory401_refreshFailsOtherwise_mapsToAuthenticationError() async {
        StubURLProtocol.script = [.status(401)]
        tokenManager.refreshError = TokenManagerError.networkUnavailable

        do {
            _ = try await client.listHistory(startHistoryId: "1")
            XCTFail("Expected authenticationError")
        } catch let error as APIError {
            guard case .authenticationError = error else {
                return XCTFail("Expected authenticationError, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testHistory401_refreshSucceeds_retriesAndSucceeds() async throws {
        StubURLProtocol.script = [
            .status(401),
            .data(200, Self.historyResponseBody)
        ]

        let response = try await client.listHistory(startHistoryId: "1")

        XCTAssertEqual(response.historyId, "99")
        XCTAssertEqual(tokenManager.refreshTokenCallCount, 1)
        XCTAssertEqual(StubURLProtocol.requestCount, 2)
    }

    // MARK: - Non-retriable 4xx mapping

    func testHistory403_mapsToInvalidDataWithoutRetry() async {
        let body = Data(#"{"error":{"code":403,"message":"insufficient permissions"}}"#.utf8)
        StubURLProtocol.script = [.data(403, body)]

        do {
            _ = try await client.listHistory(startHistoryId: "1")
            XCTFail("Expected invalidData")
        } catch let error as APIError {
            guard case .invalidData(let message) = error else {
                return XCTFail("Expected invalidData, got \(error)")
            }
            XCTAssertTrue(message.contains("403"))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertEqual(StubURLProtocol.requestCount, 1, "4xx client errors must not be retried")
    }

    // MARK: - Existing conversions stay intact

    func testHistory404_stillMapsToHistoryIdExpired() async {
        StubURLProtocol.script = [.status(404)]

        do {
            _ = try await client.listHistory(startHistoryId: "1")
            XCTFail("Expected historyIdExpired")
        } catch let error as APIError {
            guard case .historyIdExpired = error else {
                return XCTFail("Expected historyIdExpired, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testHistory429_stillRetriesAndSucceeds() async throws {
        StubURLProtocol.script = [
            .status(429),
            .data(200, Self.historyResponseBody)
        ]

        let response = try await client.listHistory(startHistoryId: "1")

        XCTAssertEqual(response.historyId, "99")
        XCTAssertEqual(StubURLProtocol.requestCount, 2)
    }

    // MARK: - BackgroundSyncErrorHandler routing

    func testErrorHandler_invalidDataAborts() {
        let handler = BackgroundSyncErrorHandler()
        let action = handler.handleError(APIError.invalidData("Gmail API 403: quota"))
        XCTAssertEqual(action, .abort)
    }

    func testErrorHandler_credentialsRevokedAbortsWithoutRetry() {
        let handler = BackgroundSyncErrorHandler()
        XCTAssertEqual(handler.handleError(APIError.credentialsRevoked), .abortNoRetry)
    }

    func testErrorHandler_serverErrorStillRetries() {
        let handler = BackgroundSyncErrorHandler()
        XCTAssertEqual(handler.handleError(APIError.serverError(502)), .retry)
    }
}
