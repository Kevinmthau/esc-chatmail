import Foundation

// MARK: - History API

extension GmailAPIClient {

    /// Lists history changes since a given history ID.
    /// Uses retry logic with circuit breaker, converting 404 to historyIdExpired.
    nonisolated func listHistory(startHistoryId: String, pageToken: String? = nil) async throws -> HistoryResponse {
        var queryItems = [URLQueryItem(name: "startHistoryId", value: startHistoryId)]
        if let pageToken = pageToken {
            queryItems.append(URLQueryItem(name: "pageToken", value: pageToken))
        }
        let url = try buildURL(endpoint: APIEndpoints.history(), queryItems: queryItems)
        let request = try await authenticatedRequest(url: url)

        return try await performHistoryRequestWithRetry(request)
    }

    /// Performs a history API request through the shared retry engine
    /// (`performRetryingRequest`), converting 404 responses to
    /// historyIdExpired errors. History-path divergences from the message
    /// path: success requires exactly 200 (other 2xx map to serverError), a
    /// non-HTTP response maps to networkError, and any APIError thrown by
    /// status handling aborts immediately instead of being mediated by
    /// RetryStrategy.
    nonisolated func performHistoryRequestWithRetry(_ request: URLRequest) async throws -> HistoryResponse {
        try await performRetryingRequest(
            request,
            behavior: GmailRetryPathBehavior(
                allowsRetransmission: true,
                thrownAPIErrorsAbortImmediately: true,
                wrapsDecodingErrors: false,
                logContext: "History request"
            )
        ) { statusCode, data in
            guard let statusCode else {
                throw APIError.networkError(URLError(.badServerResponse))
            }

            switch statusCode {
            case 200:
                await self.rateLimitTracker.recordSuccess()
                return try JSONDecoder().decode(HistoryResponse.self, from: data)

            case 404:
                // Gmail returns 404 when historyId is expired or invalid - don't retry
                if let errorResponse = try? JSONDecoder().decode(GmailErrorResponse.self, from: data) {
                    let errorMessage = errorResponse.error.message.lowercased()
                    if errorMessage.contains("not found") ||
                       errorMessage.contains("invalid") ||
                       errorMessage.contains("too old") {
                        Log.warning("History ID expired: \(errorResponse.error.message)", category: .api)
                        throw APIError.historyIdExpired
                    }
                }
                throw APIError.historyIdExpired

            case 403:
                // Reason-aware mapping shared with the message path. Note the
                // history path's thrownAPIErrorsAbortImmediately: a 403
                // rate-limit aborts this run as `.rateLimited` (recovery
                // classifies it retryable at run level) instead of spinning
                // same-request retries mid-history.
                throw self.classify403(from: data)

            case 400...499:
                // Remaining client errors (400 bad request …) are
                // non-retriable; mirrors the message path. The engine owns
                // 429/401 before this mapping is consulted.
                let errorMessage = self.gmailErrorMessage(from: data)
                    ?? HTTPURLResponse.localizedString(forStatusCode: statusCode)
                throw APIError.invalidData("Gmail API \(statusCode): \(errorMessage)")

            default:
                throw APIError.serverError(statusCode)
            }
        }
    }
}
