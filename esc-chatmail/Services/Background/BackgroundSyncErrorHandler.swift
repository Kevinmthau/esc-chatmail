import Foundation

/// Maps sync errors onto recovery actions. APIError classification is
/// canonical on the error type (`APIError.recoveryAction`); this handler only
/// adds the URLError/NSError legs for errors that never became APIErrors.
struct BackgroundSyncErrorHandler {
    /// Analyzes an error and returns the appropriate recovery action
    func handleError(_ error: Error) -> BackgroundSyncRecoveryAction {
        // Check for API errors first
        if let apiError = error as? APIError {
            let action = apiError.recoveryAction
            Log.warning(
                "API error during background sync: \(apiError) → \(action)",
                category: .background
            )
            return action
        }

        // Check for URLError before NSError — every Error bridges to NSError,
        // so the NSError branch would shadow this one if checked first.
        if let urlError = error as? URLError {
            return handleURLError(urlError)
        }

        // Check for NSError (including 404 history expired)
        if let nsError = error as NSError? {
            return handleNSError(nsError)
        }

        Log.error("Unknown error during history sync", category: .background, error: error)
        return .retry
    }

    private func handleNSError(_ nsError: NSError) -> BackgroundSyncRecoveryAction {
        if nsError.code == 404 {
            Log.info("History too old (404), falling back to partial sync", category: .background)
            return .partialSync
        }

        if nsError.code == 401 {
            Log.warning("401 Unauthorized, attempting token refresh", category: .background)
            return .tokenRefreshAndRetry
        }

        if nsError.code == 429 {
            Log.warning("Rate limited (429), will retry with backoff", category: .background)
            return .retry
        }

        return .retry
    }

    private func handleURLError(_ urlError: URLError) -> BackgroundSyncRecoveryAction {
        switch urlError.code {
        case .notConnectedToInternet, .networkConnectionLost:
            Log.info("Network unavailable during background sync", category: .background)
            // Don't increment retry count for network unavailable
            return .abortNoRetry

        case .timedOut:
            Log.warning("Request timed out during background sync", category: .background)
            return .retry

        default:
            Log.error("URL error during background sync: \(urlError)", category: .background)
            return .retry
        }
    }
}
