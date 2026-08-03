import XCTest
@testable import esc_chatmail

/// Reason-aware 403 classification against the real GmailAPIClient (mock-based
/// tests prove nothing about status handling). Gmail uses 403 for retryable
/// rate limits, quota exhaustion, and terminal policy failures; the nested
/// errors[].reason must disambiguate so rate limits retry, quota aborts the
/// run, and neither is recorded as a per-message permanent failure.
final class Gmail403ClassificationTests: XCTestCase {

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

    private static func body403(reason: String, message: String = "Limit exceeded") -> Data {
        Data("""
        {"error": {"code": 403, "message": "\(message)", "status": "PERMISSION_DENIED",
                   "errors": [{"message": "\(message)", "domain": "usageLimits", "reason": "\(reason)"}]}}
        """.utf8)
    }

    private static let messageBody = Data(#"{"id":"m1","threadId":"t1"}"#.utf8)

    // MARK: - Message path

    func testRateLimit403IsRetriedSameRequest() async throws {
        StubURLProtocol.script = [
            .data(403, Self.body403(reason: "userRateLimitExceeded")),
            .data(200, Self.messageBody)
        ]

        let message = try await client.getMessage(id: "m1", format: "full")

        XCTAssertEqual(message.id, "m1")
        XCTAssertEqual(StubURLProtocol.requestCount, 2, "A rate-limit 403 must retry like a 429, not abort")
    }

    func testDailyQuota403ThrowsQuotaExhaustedWithoutRetry() async {
        StubURLProtocol.script = [.data(403, Self.body403(reason: "dailyLimitExceeded", message: "Daily Limit Exceeded"))]

        do {
            _ = try await client.getMessage(id: "m1", format: "full")
            XCTFail("Expected quotaExhausted")
        } catch let APIError.quotaExhausted(message) {
            XCTAssertTrue(message.contains("Daily Limit Exceeded"))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertEqual(StubURLProtocol.requestCount, 1, "Quota exhaustion cannot recover by same-request retry")
    }

    func testPolicy403StaysTerminalInvalidData() async {
        StubURLProtocol.script = [.data(403, Self.body403(reason: "insufficientPermissions", message: "Insufficient Permission"))]

        do {
            _ = try await client.getMessage(id: "m1", format: "full")
            XCTFail("Expected invalidData")
        } catch let APIError.invalidData(message) {
            XCTAssertTrue(message.contains("Gmail API 403"))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertEqual(StubURLProtocol.requestCount, 1)
    }

    func testBodyless403StaysTerminalInvalidData() async {
        StubURLProtocol.script = [.status(403)]

        do {
            _ = try await client.getMessage(id: "m1", format: "full")
            XCTFail("Expected invalidData")
        } catch let APIError.invalidData(message) {
            XCTAssertTrue(message.contains("Gmail API 403"))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    // MARK: - History path

    /// The history path aborts immediately on thrown APIErrors by design; a
    /// rate-limit 403 must surface as `.rateLimited` (retryable at run level)
    /// rather than spinning same-request retries mid-history.
    func testHistoryRateLimit403AbortsRunAsRateLimited() async {
        StubURLProtocol.script = [.data(403, Self.body403(reason: "rateLimitExceeded"))]

        do {
            _ = try await client.listHistory(startHistoryId: "100", pageToken: nil)
            XCTFail("Expected rateLimited")
        } catch APIError.rateLimited {
            XCTAssertEqual(StubURLProtocol.requestCount, 1)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    // MARK: - Decoding and recovery classification

    func testGmailErrorResponseDecodesNestedReason() throws {
        let decoded = try JSONDecoder().decode(
            GmailErrorResponse.self,
            from: Self.body403(reason: "userRateLimitExceeded")
        )
        XCTAssertEqual(decoded.error.primaryReason, "userRateLimitExceeded")
        XCTAssertEqual(decoded.error.errors?.first?.domain, "usageLimits")
    }

    func testQuotaExhaustedClassifiesAsRunLevelAbortNotSameRequestRetry() {
        let error = APIError.quotaExhausted("Daily Limit Exceeded")
        XCTAssertEqual(error.recoveryAction, .abort)
        XCTAssertFalse(error.isRetriableSameRequest)
    }

    func testRateLimitedRemainsSameRequestRetriable() {
        XCTAssertTrue(APIError.rateLimited(retryAfter: nil).isRetriableSameRequest)
    }
}
