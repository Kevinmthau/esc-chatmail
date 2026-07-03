import XCTest
@testable import esc_chatmail

/// URLProtocol-level tests for retry-attempt accounting: a successful 401
/// token refresh must not consume a retry attempt in either retry loop.
/// Before this accounting, a 401 whose refresh succeeded on the final
/// attempt exited the loop as URLError(.unknown) — classified non-retriable
/// downstream, sending whole fetch batches to permanentlyFailedIds.
final class GmailAPIClientRetryAccountingTests: XCTestCase {

    private var tokenManager: MockTokenManager!

    override func setUp() {
        super.setUp()
        StubURLProtocol.reset()
        tokenManager = MockTokenManager()
    }

    override func tearDown() {
        StubURLProtocol.reset()
        tokenManager = nil
        super.tearDown()
    }

    private func makeClient(maxRetries: Int) -> GmailAPIClient {
        GmailAPIClient(
            tokenManager: tokenManager,
            retryStrategy: NetworkRetryStrategy(maxRetries: maxRetries, initialDelay: 0.01, maxDelay: 0.02),
            session: StubURLProtocol.makeSession()
        )
    }

    private static let messageBody = Data(#"{"id":"m1","threadId":"t1"}"#.utf8)
    private static let historyBody = Data(#"{"historyId":"99"}"#.utf8)

    // MARK: - Main retry loop

    func testRefreshDoesNotConsumeAttempt_singleAttemptBudget() async throws {
        // With a budget of ONE attempt, [401, 200] must still succeed:
        // the refresh grants the replacement attempt for the new token.
        StubURLProtocol.script = [
            .status(401),
            .data(200, Self.messageBody)
        ]
        let client = makeClient(maxRetries: 1)

        let message = try await client.getMessage(id: "m1")

        XCTAssertEqual(message.id, "m1")
        XCTAssertEqual(StubURLProtocol.requestCount, 2)
        XCTAssertEqual(tokenManager.refreshTokenCallCount, 1)
    }

    func testSecond401AfterRefresh_failsAsAuthenticationError() async {
        StubURLProtocol.script = [.status(401), .status(401)]
        let client = makeClient(maxRetries: 3)

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

        XCTAssertEqual(StubURLProtocol.requestCount, 2)
        XCTAssertEqual(tokenManager.refreshTokenCallCount, 1, "refresh must be once-only")
    }

    func testServerErrors_exhaustExactlyMaxRetriesAttempts() async {
        StubURLProtocol.script = [.status(500)]
        let client = makeClient(maxRetries: 3)

        do {
            _ = try await client.getMessage(id: "m1")
            XCTFail("Expected serverError")
        } catch let APIError.serverError(code) {
            XCTAssertEqual(code, 500)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertEqual(StubURLProtocol.requestCount, 3, "5xx must consume exactly the configured attempts")
    }

    func testRefreshThenServerErrorThenSuccess() async throws {
        StubURLProtocol.script = [
            .status(401),
            .status(500),
            .data(200, Self.messageBody)
        ]
        let client = makeClient(maxRetries: 3)

        let message = try await client.getMessage(id: "m1")

        XCTAssertEqual(message.id, "m1")
        XCTAssertEqual(StubURLProtocol.requestCount, 3)
    }

    func testRateLimitedOnEveryAttempt_throwsRateLimited() async {
        // Pins the 429 final-attempt guard: the loop must exit as rateLimited,
        // not fall out as URLError(.unknown).
        StubURLProtocol.script = [.status(429)]
        let client = makeClient(maxRetries: 2)

        do {
            _ = try await client.getMessage(id: "m1")
            XCTFail("Expected rateLimited")
        } catch let error as APIError {
            guard case .rateLimited = error else {
                return XCTFail("Expected rateLimited, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    // MARK: - History retry loop

    func testHistoryRefreshDoesNotConsumeAttempt_singleAttemptBudget() async throws {
        StubURLProtocol.script = [
            .status(401),
            .data(200, Self.historyBody)
        ]
        let client = makeClient(maxRetries: 1)

        let response = try await client.listHistory(startHistoryId: "1")

        XCTAssertEqual(response.historyId, "99")
        XCTAssertEqual(StubURLProtocol.requestCount, 2)
        XCTAssertEqual(tokenManager.refreshTokenCallCount, 1)
    }

    func testHistoryRateLimitedOnEveryAttempt_throwsRateLimited() async {
        // Pins the History 429 final-attempt guard (previously missing: the
        // loop slept the full Retry-After and then threw URLError(.unknown)).
        StubURLProtocol.script = [.status(429)]
        let client = makeClient(maxRetries: 2)

        do {
            _ = try await client.listHistory(startHistoryId: "1")
            XCTFail("Expected rateLimited")
        } catch let error as APIError {
            guard case .rateLimited = error else {
                return XCTFail("Expected rateLimited, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testHistoryServerErrors_exhaustExactlyMaxRetriesAttempts() async {
        StubURLProtocol.script = [.status(502)]
        let client = makeClient(maxRetries: 3)

        do {
            _ = try await client.listHistory(startHistoryId: "1")
            XCTFail("Expected serverError")
        } catch let APIError.serverError(code) {
            XCTAssertEqual(code, 502)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertEqual(StubURLProtocol.requestCount, 3)
    }
}
