import XCTest
@testable import esc_chatmail

/// URLProtocol-level tests for the retry-budgeted getMessage witness and the
/// MessageFetcher single-retry-owner interaction. These run against the real
/// GmailAPIClient — MockGmailAPIClient replaces the whole client, so
/// mock-based tests prove nothing about budget/retry semantics.
final class GmailAPIClientRetryBudgetTests: XCTestCase {

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

    private static let messageBody = Data(#"{"id":"m1","threadId":"t1"}"#.utf8)

    // MARK: - maxRetries budget on the real witness

    func testBudgetOfOne_serverError_makesExactlyOneRequest() async {
        StubURLProtocol.script = [.status(500)]

        do {
            _ = try await client.getMessage(id: "m1", format: "full", maxRetries: 1)
            XCTFail("Expected serverError")
        } catch let APIError.serverError(code) {
            XCTAssertEqual(code, 500)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertEqual(StubURLProtocol.requestCount, 1, "budget of 1 means one total attempt")
    }

    func testBudgetOfOne_refreshedTokenStillGetsItsRequest() async throws {
        // The M2+M6 interaction: with a single-attempt budget, [401, 200] must
        // still succeed because a successful refresh grants the replacement
        // attempt. Without that grant the first sync after routine token
        // expiry would drop the whole batch.
        StubURLProtocol.script = [
            .status(401),
            .data(200, Self.messageBody)
        ]

        let message = try await client.getMessage(id: "m1", format: "full", maxRetries: 1)

        XCTAssertEqual(message.id, "m1")
        XCTAssertEqual(StubURLProtocol.requestCount, 2)
        XCTAssertEqual(tokenManager.refreshTokenCallCount, 1)
    }

    func testBudgetOfOne_rateLimited_carriesRetryAfterWithoutSleepingOrRecordingBackoff() async {
        StubURLProtocol.script = [
            .dataWithHeaders(429, Data(), ["Retry-After": "7"])
        ]

        let start = Date()
        do {
            _ = try await client.getMessage(id: "m1", format: "full", maxRetries: 1)
            XCTFail("Expected rateLimited")
        } catch let APIError.rateLimited(retryAfter) {
            XCTAssertEqual(retryAfter, 7)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        // Final-attempt 429 must not sleep the Retry-After...
        XCTAssertLessThan(Date().timeIntervalSince(start), 2.0)
        // ...and must not record backoff it never slept (N concurrent 429s
        // would otherwise trip the shared 120s breaker with nobody waiting).
        let recorded = await client.rateLimitTracker.currentCumulativeBackoff
        XCTAssertEqual(recorded, 0, accuracy: 0.001)
    }

    func testDefaultNilBudget_keepsConfiguredStrategy() async throws {
        StubURLProtocol.script = [
            .status(500),
            .data(200, Self.messageBody)
        ]

        let message = try await client.getMessage(id: "m1", format: "full", maxRetries: nil)

        XCTAssertEqual(message.id, "m1")
        XCTAssertEqual(StubURLProtocol.requestCount, 2, "nil budget retries per the configured strategy")
    }

    // MARK: - MessageFetcher owns the retry policy

    func testFetchBatch_retriesOnceOwnedByFetcher_andSucceeds() async throws {
        // First pass 500 (single client attempt), fetcher's outer loop retries
        // and the second pass succeeds. The client must not multiply attempts.
        StubURLProtocol.script = [
            .status(500),
            .data(200, Self.messageBody)
        ]
        let fetcher = MessageFetcher(apiClient: client)

        let recorder = FetchRecorder()
        let outcome = try await fetcher.fetchBatch(["m1"]) { messages in
            await recorder.record(messages.map(\.id))
            return .empty
        }

        XCTAssertTrue(outcome.blockingFailureIds.isEmpty)
        let persisted = await recorder.snapshot()
        XCTAssertEqual(persisted, [["m1"]])
        XCTAssertEqual(StubURLProtocol.requestCount, 2, "one attempt per fetcher pass — no stacked client retries")
    }

    func testFetchBatch_notFound_isGoneWithoutRetry() async throws {
        StubURLProtocol.script = [.status(404)]
        let fetcher = MessageFetcher(apiClient: client)

        let recorder = FetchRecorder()
        let outcome = try await fetcher.fetchBatch(["gone"]) { messages in
            await recorder.record(messages.map(\.id))
            return .empty
        }

        XCTAssertEqual(outcome.goneIds, ["gone"], "A 404 is a terminal outcome (gone), not a blocking failure")
        XCTAssertTrue(outcome.fetchFailedIds.isEmpty)
        XCTAssertEqual(StubURLProtocol.requestCount, 1, "404 must not burn retry passes")
    }
}

private actor FetchRecorder {
    private var batches: [[String]] = []

    func record(_ ids: [String]) {
        batches.append(ids)
    }

    func snapshot() -> [[String]] {
        batches
    }
}
