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

    // MARK: - Request shape

    func testListHistoryAppendsMaxResultsQueryItemOnlyWhenProvided() async throws {
        StubURLProtocol.script = [.data(200, Self.historyResponseBody)]

        _ = try await client.listHistory(startHistoryId: "1", maxResults: 40)
        _ = try await client.listHistory(startHistoryId: "1")

        let urls = StubURLProtocol.requestURLs
        XCTAssertEqual(urls.count, 2)
        let cappedItems = URLComponents(
            url: urls[0],
            resolvingAgainstBaseURL: false
        )?.queryItems ?? []
        XCTAssertTrue(cappedItems.contains(URLQueryItem(name: "maxResults", value: "40")))
        XCTAssertTrue(cappedItems.contains(URLQueryItem(name: "startHistoryId", value: "1")))
        let defaultItems = URLComponents(
            url: urls[1],
            resolvingAgainstBaseURL: false
        )?.queryItems ?? []
        XCTAssertFalse(
            defaultItems.contains { $0.name == "maxResults" },
            "A nil cap must leave the server default in effect"
        )
    }

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

    func testHistory400_invalidPageToken_mapsToTypedErrorWithoutRetry() async {
        let body = Data(#"{"error":{"code":400,"message":"Invalid pageToken"}}"#.utf8)
        StubURLProtocol.script = [.data(400, body)]

        do {
            _ = try await client.listHistory(startHistoryId: "1", pageToken: "opaque-token")
            XCTFail("Expected invalidHistoryPageToken")
        } catch let error as APIError {
            guard case .invalidHistoryPageToken = error else {
                return XCTFail("Expected invalidHistoryPageToken, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertEqual(StubURLProtocol.requestCount, 1)
    }

    func testHistory400_invalidPageTokenInLaterErrorItem_mapsToTypedError() async {
        let body = Data(
            #"{"error":{"code":400,"message":"Bad Request","errors":[{"reason":"badRequest"},{"reason":"invalidPageToken"}]}}"#.utf8
        )
        StubURLProtocol.script = [.data(400, body)]

        do {
            _ = try await client.listHistory(startHistoryId: "1", pageToken: "opaque-token")
            XCTFail("Expected invalidHistoryPageToken")
        } catch let error as APIError {
            guard case .invalidHistoryPageToken = error else {
                return XCTFail("Expected invalidHistoryPageToken, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertEqual(StubURLProtocol.requestCount, 1)
    }

    func testHistory404_messageOnlyInvalidPageToken_mapsToTypedError() async {
        let body = Data(
            #"{"error":{"code":404,"message":"Invalid pageToken"}}"#.utf8
        )
        StubURLProtocol.script = [.data(404, body)]

        do {
            _ = try await client.listHistory(startHistoryId: "1", pageToken: "opaque-token")
            XCTFail("Expected invalidHistoryPageToken")
        } catch let error as APIError {
            guard case .invalidHistoryPageToken = error else {
                return XCTFail("Expected invalidHistoryPageToken, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertEqual(StubURLProtocol.requestCount, 1)
    }

    /// The explicit reason must win over the generic "invalid" 404 keyword.
    func testHistory404_invalidPageTokenReason_mapsToTypedError() async {
        let body = Data(
            #"{"error":{"code":404,"message":"Invalid pageToken","errors":[{"reason":"invalidPageToken"}]}}"#.utf8
        )
        StubURLProtocol.script = [.data(404, body)]

        do {
            _ = try await client.listHistory(startHistoryId: "1", pageToken: "opaque-token")
            XCTFail("Expected invalidHistoryPageToken")
        } catch let error as APIError {
            guard case .invalidHistoryPageToken = error else {
                return XCTFail("Expected invalidHistoryPageToken, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testHistory400_unrelatedErrorWithPageToken_staysInvalidData() async {
        let body = Data(#"{"error":{"code":400,"message":"Invalid label filter"}}"#.utf8)
        StubURLProtocol.script = [.data(400, body)]

        do {
            _ = try await client.listHistory(startHistoryId: "1", pageToken: "opaque-token")
            XCTFail("Expected invalidData")
        } catch let error as APIError {
            guard case .invalidData = error else {
                return XCTFail("Expected invalidData, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    // MARK: - Expired-cursor classification wins the 404 (Finding 3)

    // REVERT-CHECK (Finding 3b): the structured page-token classifier runs
    // before generic 404 keyword classification, but deliberately excludes a
    // response whose message names startHistoryId. This body therefore falls
    // through to the expired-cursor branch even though it also names pageToken.
    func testHistory404_expiredHistoryBodyNamingPageToken_stillMapsToHistoryIdExpired() async {
        let body = Data(
            #"{"error":{"code":404,"message":"Invalid startHistoryId; the supplied pageToken cannot be used","errors":[{"reason":"notFound"}]}}"#.utf8
        )
        StubURLProtocol.script = [.data(404, body)]

        do {
            _ = try await client.listHistory(startHistoryId: "1", pageToken: "opaque-token")
            XCTFail("Expected historyIdExpired")
        } catch let error as APIError {
            guard case .historyIdExpired = error else {
                return XCTFail(
                    """
                    Expected historyIdExpired, got \(error). An expired history \
                    cursor misrouted to .invalidHistoryPageToken deadlocks \
                    incremental sync: BackgroundSyncErrorHandler maps that case \
                    to .abort with no recovery branch, so the stale cursor is \
                    never replaced and every subsequent run aborts the same way. \
                    The reverse mistake only costs one recovery pass.
                    """
                )
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertEqual(StubURLProtocol.requestCount, 1, "4xx client errors must not be retried")
    }

    // REVERT-CHECK (Finding 3a): fails if isInvalidHistoryPageTokenResponse
    // folds the raw response body back into its match string. The decoded
    // message ("Requested entity has expired") and reason ("expired") never
    // name a page token — only the raw `details` payload does — so a raw-body
    // fold is the only way this can be classified as
    // `.invalidHistoryPageToken`. Note this 404 also misses the expired
    // keywords in the first branch, so it exercises the raw-body removal in
    // isolation from the Finding 3b reordering.
    func testHistory404_pageTokenOnlyInRawBody_doesNotClassifyAsInvalidPageToken() async {
        let body = Data(
            #"""
            {"error":{"code":404,"message":"Requested entity has expired","errors":[{"reason":"expired"}],"details":[{"@type":"type.googleapis.com/google.rpc.DebugInfo","detail":"pageToken=CAUQ_aiv rejected downstream"}]}}
            """#.utf8
        )
        StubURLProtocol.script = [.data(404, body)]

        do {
            _ = try await client.listHistory(startHistoryId: "1", pageToken: "opaque-token")
            XCTFail("Expected historyIdExpired")
        } catch let error as APIError {
            guard case .historyIdExpired = error else {
                return XCTFail(
                    """
                    Expected historyIdExpired, got \(error). "pageToken" \
                    appearing anywhere in the raw payload must not launder an \
                    expired cursor into the recovery-less \
                    .invalidHistoryPageToken abort.
                    """
                )
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertEqual(StubURLProtocol.requestCount, 1, "4xx client errors must not be retried")
    }

    // REVERT-CHECK (Finding 3a, second call site): fails if
    // isInvalidHistoryPageTokenResponse folds the raw response body into its
    // match string. The decoded message ("Invalid label filter") supplies the
    // "invalid" keyword but never names a page token; only the raw `details`
    // payload does. Pins the generic `case 400...499` call site: an unrelated
    // malformed request must stay `.invalidData` rather than be laundered into
    // a checkpoint replay.
    func testHistory400_pageTokenOnlyInRawBody_staysInvalidData() async {
        let body = Data(
            #"""
            {"error":{"code":400,"message":"Invalid label filter","details":[{"@type":"type.googleapis.com/google.rpc.BadRequest","fieldViolations":[{"field":"pageToken","description":"unused"}]}]}}
            """#.utf8
        )
        StubURLProtocol.script = [.data(400, body)]

        do {
            _ = try await client.listHistory(startHistoryId: "1", pageToken: "opaque-token")
            XCTFail("Expected invalidData")
        } catch let error as APIError {
            guard case .invalidData(let message) = error else {
                return XCTFail(
                    """
                    Expected invalidData, got \(error). A raw-body "pageToken" \
                    mention must not turn an unrelated 400 into a page-token \
                    rejection.
                    """
                )
            }
            XCTAssertTrue(message.contains("400"))
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

    func testErrorHandler_invalidHistoryPageTokenAborts() {
        let handler = BackgroundSyncErrorHandler()
        XCTAssertEqual(handler.handleError(APIError.invalidHistoryPageToken), .abort)
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
