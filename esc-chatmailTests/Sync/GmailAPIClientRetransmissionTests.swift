import XCTest
@testable import esc_chatmail

private actor GmailSendAdmissionProbe {
    private(set) var callCount = 0

    func record() {
        callCount += 1
    }
}

private final class ProbedNetworkRetryStrategy: RetryStrategy, @unchecked Sendable {
    let maxRetries: Int
    let initialDelay: TimeInterval
    let maxDelay: TimeInterval

    private let base: NetworkRetryStrategy
    private let lock = NSLock()
    private var _retryDecisionCount = 0

    init(maxRetries: Int, initialDelay: TimeInterval, maxDelay: TimeInterval) {
        self.maxRetries = maxRetries
        self.initialDelay = initialDelay
        self.maxDelay = maxDelay
        self.base = NetworkRetryStrategy(
            maxRetries: maxRetries,
            initialDelay: initialDelay,
            maxDelay: maxDelay
        )
    }

    var retryDecisionCount: Int {
        lock.withLock { _retryDecisionCount }
    }

    func shouldRetry(error: Error, attempt: Int) -> Bool {
        let shouldRetry = base.shouldRetry(error: error, attempt: attempt)
        if shouldRetry {
            lock.withLock { _retryDecisionCount += 1 }
        }
        return shouldRetry
    }
}

/// Verifies that non-idempotent requests (messages.send) are never retransmitted
/// after ambiguous failures, while idempotent requests keep full retry behavior.
final class GmailAPIClientRetransmissionTests: XCTestCase {

    private var tokenManager: MockTokenManager!
    private var client: GmailAPIClient!

    override func setUp() {
        super.setUp()
        StubURLProtocol.reset()

        let session = StubURLProtocol.makeSession()

        tokenManager = MockTokenManager()
        client = GmailAPIClient(
            tokenManager: tokenManager,
            retryStrategy: NetworkRetryStrategy(maxRetries: 3, initialDelay: 0.01, maxDelay: 0.02),
            session: session
        )
    }

    override func tearDown() {
        StubURLProtocol.reset()
        client = nil
        tokenManager = nil
        super.tearDown()
    }

    private static let sendResponseBody = Data(#"{"id":"sent-1","threadId":"thread-1"}"#.utf8)
    private static let messageResponseBody = Data(#"{"id":"m1","threadId":"t1"}"#.utf8)
    private static let userRateLimitBody = Data(
        #"{"error":{"code":403,"message":"User rate limit exceeded","status":"PERMISSION_DENIED","errors":[{"message":"User rate limit exceeded","domain":"usageLimits","reason":"userRateLimitExceeded"}]}}"#.utf8
    )

    // MARK: - Send is not retransmitted on ambiguous failures

    func testSendMessage_authPreflightFailure_doesNotCrossAdmissionBarrier() async {
        tokenManager.getTokenError = TokenManagerError.noValidToken
        let admissionProbe = GmailSendAdmissionProbe()

        do {
            _ = try await client.sendMessage(
                rawMessage: "raw",
                beforeTransmission: {
                    await admissionProbe.record()
                }
            )
            XCTFail("Expected authentication preflight failure")
        } catch GmailMessageSendError.transmissionNotStarted(let underlying) {
            guard let tokenError = underlying as? TokenManagerError,
                  case .noValidToken = tokenError else {
                return XCTFail("Expected noValidToken, got \(underlying)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        let admissionCallCount = await admissionProbe.callCount
        XCTAssertEqual(admissionCallCount, 0)
        XCTAssertEqual(StubURLProtocol.requestCount, 0)
    }

    func testSendMessage_serverError_isNotRetransmitted() async {
        StubURLProtocol.script = [.status(500)]

        do {
            _ = try await client.sendMessage(rawMessage: "raw")
            XCTFail("Expected ambiguous delivery")
        } catch GmailMessageSendError.ambiguousDelivery(let underlying) {
            guard case APIError.serverError(let code) = underlying else {
                return XCTFail("Expected underlying serverError, got \(underlying)")
            }
            XCTAssertEqual(code, 500)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertEqual(StubURLProtocol.requestCount, 1, "A 5xx is ambiguous for send; it must not be retransmitted")
    }

    func testSendMessage_timeout_isNotRetransmitted() async {
        StubURLProtocol.script = [.error(URLError(.timedOut))]

        do {
            _ = try await client.sendMessage(rawMessage: "raw")
            XCTFail("Expected ambiguous delivery")
        } catch GmailMessageSendError.ambiguousDelivery(let underlying) {
            XCTAssertEqual((underlying as? URLError)?.code, .timedOut)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertEqual(StubURLProtocol.requestCount, 1, "A timeout is ambiguous for send; it must not be retransmitted")
    }

    func testSendMessage_connectionLost_isNotRetransmitted() async {
        StubURLProtocol.script = [.error(URLError(.networkConnectionLost))]

        do {
            _ = try await client.sendMessage(rawMessage: "raw")
            XCTFail("Expected ambiguous delivery")
        } catch GmailMessageSendError.ambiguousDelivery(let underlying) {
            XCTAssertEqual((underlying as? URLError)?.code, .networkConnectionLost)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertEqual(StubURLProtocol.requestCount, 1, "A dropped connection is ambiguous for send; it must not be retransmitted")
    }

    // MARK: - Send is still retried when the request provably never went through

    func testSendMessage_cannotConnect_isRetried() async throws {
        StubURLProtocol.script = [
            .error(URLError(.cannotConnectToHost)),
            .data(200, Self.sendResponseBody)
        ]

        let response = try await client.sendMessage(rawMessage: "raw")

        XCTAssertEqual(response.id, "sent-1")
        XCTAssertEqual(StubURLProtocol.requestCount, 2, "Connect failures prove the request was never delivered; retry is safe")
    }

    func testSendMessage_tlsHandshakeFailure_isRetried() async throws {
        StubURLProtocol.script = [
            .error(URLError(.secureConnectionFailed)),
            .data(200, Self.sendResponseBody)
        ]

        let response = try await client.sendMessage(rawMessage: "raw")

        XCTAssertEqual(response.id, "sent-1")
        XCTAssertEqual(StubURLProtocol.requestCount, 2, "A TLS handshake failure proves no application data was sent; retry is safe")
    }

    func testSendMessage_definiteClientRejection_isNotAmbiguous() async {
        StubURLProtocol.script = [.status(400)]

        do {
            _ = try await client.sendMessage(rawMessage: "raw")
            XCTFail("Expected definite client rejection")
        } catch is GmailMessageSendError {
            XCTFail("A 400 response proves Gmail rejected the send")
        } catch {
            // Expected ordinary API error; optimistic failure cleanup remains enabled.
        }

        XCTAssertEqual(StubURLProtocol.requestCount, 1)
    }

    func testSendMessage_rateLimited_isRetried() async throws {
        StubURLProtocol.script = [
            .status(429),
            .data(200, Self.sendResponseBody)
        ]

        let response = try await client.sendMessage(rawMessage: "raw")

        XCTAssertEqual(response.id, "sent-1")
        XCTAssertEqual(StubURLProtocol.requestCount, 2, "A 429 proves the request was rejected; retry is safe")
    }

    func testSendMessage_userRateLimit403_isRetried() async throws {
        StubURLProtocol.script = [
            .data(403, Self.userRateLimitBody),
            .data(200, Self.sendResponseBody)
        ]

        let response = try await client.sendMessage(rawMessage: "raw")

        XCTAssertEqual(response.id, "sent-1")
        XCTAssertEqual(
            StubURLProtocol.requestCount,
            2,
            "A rate-limit 403 proves the send was rejected and is safe to retry"
        )
    }

    // Revert-check: fails if `GmailAPIClient.sleepBeforeRetry()` stops throwing
    // `RetryCancelledBeforeRetransmission` on the `allowsRetransmission: false` backoff
    // path — cancellation during the 429 backoff would surface as `ambiguousDelivery` again.
    func testSendMessage_cancellationDuring429Backoff_isDefinite() async {
        installLongBackoffClient()
        StubURLProtocol.script = [
            .status(429),
            .data(200, Self.sendResponseBody)
        ]

        let task = Task {
            try await client.sendMessage(rawMessage: "raw")
        }

        let enteredBackoff = await waitUntil {
            await self.client.rateLimitTracker.currentCumulativeBackoff > 0
        }
        guard enteredBackoff else {
            task.cancel()
            _ = try? await task.value
            return XCTFail("Timed out waiting for the 429 backoff")
        }
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Expected cancellation before retransmission")
        } catch let error as GmailAPIClient.RetryCancelledBeforeRetransmission {
            guard let apiError = error.lastFailure as? APIError,
                  case .rateLimited = apiError else {
                return XCTFail("Expected a definite rate-limit rejection, got \(error.lastFailure)")
            }
        } catch GmailMessageSendError.ambiguousDelivery(let underlying) {
            XCTFail("Cancellation during a definite backoff is not ambiguous: \(underlying)")
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertEqual(StubURLProtocol.requestCount, 1)
    }

    // Revert-check: fails if `GmailAPIClient.sleepBeforeRetry()` no longer covers the
    // rate-limit-403 sleep site reached via `isDefiniteRetryableRejection` — that backoff
    // follows a provably rejected send, so cancellation there must stay definite.
    func testSendMessage_cancellationDuringRateLimit403Backoff_isDefinite() async {
        let retryProbe = installLongBackoffClient()
        StubURLProtocol.script = [
            .data(403, Self.userRateLimitBody),
            .data(200, Self.sendResponseBody)
        ]

        let task = Task {
            try await client.sendMessage(rawMessage: "raw")
        }

        let enteredBackoff = await waitUntil {
            retryProbe.retryDecisionCount > 0
        }
        guard enteredBackoff else {
            task.cancel()
            _ = try? await task.value
            return XCTFail("Timed out waiting for the 403 backoff")
        }
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Expected cancellation before retransmission")
        } catch let error as GmailAPIClient.RetryCancelledBeforeRetransmission {
            guard let apiError = error.lastFailure as? APIError,
                  case .rateLimited = apiError else {
                return XCTFail("Expected a definite rate-limit rejection, got \(error.lastFailure)")
            }
        } catch GmailMessageSendError.ambiguousDelivery(let underlying) {
            XCTFail("Cancellation during a definite backoff is not ambiguous: \(underlying)")
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertEqual(StubURLProtocol.requestCount, 1)
    }

    // Revert-check: fails if `GmailAPIClient.sleepBeforeRetry()` no longer covers the
    // pre-transmission connection-failure sleep site (`ConnectionErrorDetector.isPreTransmissionError`)
    // — the request never reached the wire, so cancellation there must stay definite.
    func testSendMessage_cancellationDuringPreTransmissionBackoff_isDefinite() async {
        let retryProbe = installLongBackoffClient()
        StubURLProtocol.script = [
            .error(URLError(.cannotConnectToHost)),
            .data(200, Self.sendResponseBody)
        ]

        let task = Task {
            try await client.sendMessage(rawMessage: "raw")
        }

        let enteredBackoff = await waitUntil {
            retryProbe.retryDecisionCount > 0
        }
        guard enteredBackoff else {
            task.cancel()
            _ = try? await task.value
            return XCTFail("Timed out waiting for the connection-failure backoff")
        }
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Expected cancellation before retransmission")
        } catch let error as GmailAPIClient.RetryCancelledBeforeRetransmission {
            XCTAssertEqual((error.lastFailure as? URLError)?.code, .cannotConnectToHost)
        } catch GmailMessageSendError.ambiguousDelivery(let underlying) {
            XCTFail("Cancellation before a safe retransmission is not ambiguous: \(underlying)")
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertEqual(StubURLProtocol.requestCount, 1)
    }

    func testSendMessage_unauthorized_refreshesTokenAndRetries() async throws {
        StubURLProtocol.script = [
            .status(401),
            .data(200, Self.sendResponseBody)
        ]

        let response = try await client.sendMessage(rawMessage: "raw")

        XCTAssertEqual(response.id, "sent-1")
        XCTAssertEqual(StubURLProtocol.requestCount, 2, "A 401 proves the request was rejected; refresh + retry is safe")
        XCTAssertEqual(tokenManager.refreshTokenCallCount, 1)
    }

    // MARK: - Idempotent requests keep full retry behavior

    func testGetMessage_serverError_isRetried() async throws {
        StubURLProtocol.script = [
            .status(500),
            .data(200, Self.messageResponseBody)
        ]

        let message = try await client.getMessage(id: "m1")

        XCTAssertEqual(message.id, "m1")
        XCTAssertEqual(StubURLProtocol.requestCount, 2, "Idempotent requests must keep retrying 5xx responses")
    }

    func testGetMessage_timeout_isRetried() async throws {
        StubURLProtocol.script = [
            .error(URLError(.timedOut)),
            .data(200, Self.messageResponseBody)
        ]

        let message = try await client.getMessage(id: "m1")

        XCTAssertEqual(message.id, "m1")
        XCTAssertEqual(StubURLProtocol.requestCount, 2, "Idempotent requests must keep retrying timeouts")
    }

    @discardableResult
    private func installLongBackoffClient() -> ProbedNetworkRetryStrategy {
        let retryStrategy = ProbedNetworkRetryStrategy(
            maxRetries: 3,
            initialDelay: 30,
            maxDelay: 30
        )
        client = GmailAPIClient(
            tokenManager: tokenManager,
            retryStrategy: retryStrategy,
            session: StubURLProtocol.makeSession()
        )
        return retryStrategy
    }

    private func waitUntil(
        timeout: TimeInterval = 2,
        _ condition: () async -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() {
                return true
            }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        return await condition()
    }
}
