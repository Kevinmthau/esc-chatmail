import XCTest
@testable import esc_chatmail

/// CX3 characterization: pins the error-classification behavior of the retry
/// and background-sync seams across the full APIError matrix, so the
/// consolidation onto `APIError.recoveryAction` is observable row by row.
final class APIErrorClassificationTests: XCTestCase {

    private let retryStrategy = NetworkRetryStrategy(maxRetries: 5)
    private let backgroundHandler = BackgroundSyncErrorHandler()

    private func shouldRetry(_ error: Error) -> Bool {
        retryStrategy.shouldRetry(error: error, attempt: 0)
    }

    // MARK: - RetryStrategy APIError matrix (same-request retriability)

    func testRetryStrategy_transientErrors_areRetriable() {
        XCTAssertTrue(shouldRetry(APIError.rateLimited(retryAfter: nil)))
        XCTAssertTrue(shouldRetry(APIError.rateLimited(retryAfter: 12)))
        XCTAssertTrue(shouldRetry(APIError.timeout))
        XCTAssertTrue(shouldRetry(APIError.networkError(URLError(.networkConnectionLost))))
        XCTAssertTrue(shouldRetry(APIError.serverError(500)))
        XCTAssertTrue(shouldRetry(APIError.serverError(503)))
    }

    func testRetryStrategy_terminalErrors_areNotRetriable() {
        XCTAssertFalse(shouldRetry(APIError.authenticationError))
        XCTAssertFalse(shouldRetry(APIError.credentialsRevoked))
        XCTAssertFalse(shouldRetry(APIError.decodingError(URLError(.cannotParseResponse))))
        XCTAssertFalse(shouldRetry(APIError.invalidURL("bad url")))
        XCTAssertFalse(shouldRetry(APIError.invalidData("Gmail API 403: quota")))
        XCTAssertFalse(shouldRetry(APIError.invalidHistoryPageToken))
        XCTAssertFalse(shouldRetry(APIError.historyIdExpired))
        XCTAssertFalse(shouldRetry(APIError.notFound("message")))
    }

    func testRetryStrategy_attemptBudgetGuard_overridesClassification() {
        let strategy = NetworkRetryStrategy(maxRetries: 2)
        XCTAssertTrue(strategy.shouldRetry(error: APIError.timeout, attempt: 1))
        XCTAssertFalse(strategy.shouldRetry(error: APIError.timeout, attempt: 2))
        XCTAssertFalse(strategy.shouldRetry(error: APIError.timeout, attempt: 3))
    }

    // MARK: - BackgroundSyncErrorHandler APIError matrix

    func testBackgroundHandler_historyIdExpired_fallsBackToPartialSync() {
        XCTAssertEqual(backgroundHandler.handleError(APIError.historyIdExpired), .partialSync)
    }

    func testBackgroundHandler_authenticationError_refreshesToken() {
        XCTAssertEqual(backgroundHandler.handleError(APIError.authenticationError), .tokenRefreshAndRetry)
    }

    func testBackgroundHandler_credentialsRevoked_abortsWithoutRetry() {
        XCTAssertEqual(backgroundHandler.handleError(APIError.credentialsRevoked), .abortNoRetry)
    }

    func testBackgroundHandler_transientErrors_retry() {
        XCTAssertEqual(backgroundHandler.handleError(APIError.rateLimited(retryAfter: nil)), .retry)
        XCTAssertEqual(backgroundHandler.handleError(APIError.timeout), .retry)
        XCTAssertEqual(backgroundHandler.handleError(APIError.networkError(URLError(.networkConnectionLost))), .retry)
        XCTAssertEqual(backgroundHandler.handleError(APIError.serverError(500)), .retry)
        XCTAssertEqual(backgroundHandler.handleError(APIError.serverError(503)), .retry)
    }

    func testBackgroundHandler_clientServerErrorCodes_abort() {
        XCTAssertEqual(backgroundHandler.handleError(APIError.serverError(400)), .abort)
        XCTAssertEqual(backgroundHandler.handleError(APIError.serverError(451)), .abort)
    }

    func testBackgroundHandler_invalidData_aborts() {
        XCTAssertEqual(backgroundHandler.handleError(APIError.invalidData("Gmail API 403: quota")), .abort)
    }

    func testBackgroundHandler_malformedRequestOrResponseErrors_abort() {
        // CX3 decision: these previously fell through `default:` to .retry
        // even though retrying cannot succeed (the M1 inverted-intent bug
        // class). The canonical mapping classifies them as .abort, matching
        // every same-request retry classifier.
        XCTAssertEqual(backgroundHandler.handleError(APIError.invalidURL("bad url")), .abort)
        XCTAssertEqual(backgroundHandler.handleError(APIError.decodingError(URLError(.cannotParseResponse))), .abort)
        XCTAssertEqual(backgroundHandler.handleError(APIError.notFound("message")), .abort)
        XCTAssertEqual(backgroundHandler.handleError(APIError.invalidHistoryPageToken), .abort)
    }

    // MARK: - Canonical mapping matrix (APIError.recoveryAction)

    func testRecoveryAction_coversEveryCase() {
        XCTAssertEqual(APIError.historyIdExpired.recoveryAction, .partialSync)
        XCTAssertEqual(APIError.authenticationError.recoveryAction, .tokenRefreshAndRetry)
        XCTAssertEqual(APIError.credentialsRevoked.recoveryAction, .abortNoRetry)
        XCTAssertEqual(APIError.rateLimited(retryAfter: nil).recoveryAction, .retry)
        XCTAssertEqual(APIError.rateLimited(retryAfter: 30).recoveryAction, .retry)
        XCTAssertEqual(APIError.timeout.recoveryAction, .retry)
        XCTAssertEqual(APIError.networkError(URLError(.networkConnectionLost)).recoveryAction, .retry)
        XCTAssertEqual(APIError.serverError(500).recoveryAction, .retry)
        XCTAssertEqual(APIError.serverError(503).recoveryAction, .retry)
        XCTAssertEqual(APIError.serverError(400).recoveryAction, .abort)
        XCTAssertEqual(APIError.invalidURL("bad url").recoveryAction, .abort)
        XCTAssertEqual(APIError.invalidData("Gmail API 403: quota").recoveryAction, .abort)
        XCTAssertEqual(APIError.invalidHistoryPageToken.recoveryAction, .abort)
        XCTAssertEqual(APIError.decodingError(URLError(.cannotParseResponse)).recoveryAction, .abort)
        XCTAssertEqual(APIError.notFound("message").recoveryAction, .abort)
    }

    func testIsRetriableSameRequest_onlyForPlainRetry() {
        // partialSync and tokenRefreshAndRetry recover by doing something
        // different — same-request retry loops must not spin on them.
        XCTAssertTrue(APIError.timeout.isRetriableSameRequest)
        XCTAssertTrue(APIError.rateLimited(retryAfter: nil).isRetriableSameRequest)
        XCTAssertTrue(APIError.serverError(502).isRetriableSameRequest)
        XCTAssertFalse(APIError.historyIdExpired.isRetriableSameRequest)
        XCTAssertFalse(APIError.authenticationError.isRetriableSameRequest)
        XCTAssertFalse(APIError.credentialsRevoked.isRetriableSameRequest)
        XCTAssertFalse(APIError.notFound("message").isRetriableSameRequest)
        XCTAssertFalse(APIError.invalidData("payload").isRetriableSameRequest)
        XCTAssertFalse(APIError.invalidHistoryPageToken.isRetriableSameRequest)
    }

    func testRetryStrategy_agreesWithCanonicalMapping() {
        let errors: [APIError] = [
            .invalidURL("bad url"),
            .networkError(URLError(.networkConnectionLost)),
            .decodingError(URLError(.cannotParseResponse)),
            .invalidData("payload"),
            .invalidHistoryPageToken,
            .authenticationError,
            .credentialsRevoked,
            .rateLimited(retryAfter: nil),
            .serverError(500),
            .serverError(404),
            .timeout,
            .historyIdExpired,
            .notFound("message")
        ]
        for error in errors {
            XCTAssertEqual(
                shouldRetry(error),
                error.isRetriableSameRequest,
                "RetryStrategy diverged from canonical mapping for \(error)"
            )
        }
    }

    // MARK: - BackgroundSyncErrorHandler non-APIError legs

    func testBackgroundHandler_urlErrors() {
        XCTAssertEqual(backgroundHandler.handleError(URLError(.notConnectedToInternet)), .abortNoRetry)
        XCTAssertEqual(backgroundHandler.handleError(URLError(.networkConnectionLost)), .abortNoRetry)
        XCTAssertEqual(backgroundHandler.handleError(URLError(.timedOut)), .retry)
        XCTAssertEqual(backgroundHandler.handleError(URLError(.cannotConnectToHost)), .retry)
    }

    func testBackgroundHandler_nsErrorStatusCodes() {
        XCTAssertEqual(
            backgroundHandler.handleError(NSError(domain: "test", code: 404)), .partialSync
        )
        XCTAssertEqual(
            backgroundHandler.handleError(NSError(domain: "test", code: 401)), .tokenRefreshAndRetry
        )
        XCTAssertEqual(
            backgroundHandler.handleError(NSError(domain: "test", code: 429)), .retry
        )
        XCTAssertEqual(
            backgroundHandler.handleError(NSError(domain: "test", code: 1)), .retry
        )
    }
}
