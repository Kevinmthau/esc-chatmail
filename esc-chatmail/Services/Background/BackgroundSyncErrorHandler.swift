import Foundation

/// Defines recovery actions for background sync errors
enum BackgroundSyncRecoveryAction {
    case retry
    case partialSync
    case tokenRefreshAndRetry
    case abort
    case abortNoRetry
}

/// Handles error classification and recovery strategy determination
struct BackgroundSyncErrorHandler {
    /// Analyzes an error and returns the appropriate recovery action
    func handleError(_ error: Error) -> BackgroundSyncRecoveryAction {
        // Check for API errors first
        if let apiError = error as? APIError {
            return handleAPIError(apiError)
        }

        // Check for NSError (including 404 history expired)
        if let nsError = error as NSError? {
            return handleNSError(nsError)
        }

        // Check for URLError
        if let urlError = error as? URLError {
            return handleURLError(urlError)
        }

        Log.error("Unknown error during history sync", category: .background, error: error)
        return .retry
    }

    private func handleAPIError(_ apiError: APIError) -> BackgroundSyncRecoveryAction {
        switch apiError {
        case .historyIdExpired:
            Log.info("History ID expired (APIError), falling back to partial sync", category: .background)
            return .partialSync

        case .authenticationError:
            Log.warning("Authentication error during background sync, attempting token refresh", category: .background)
            return .tokenRefreshAndRetry

        case .rateLimited:
            Log.warning("Rate limited during background sync, will retry with backoff", category: .background)
            return .retry

        case .timeout, .networkError:
            Log.warning("Network issue during background sync: \(apiError)", category: .background)
            return .retry

        case .serverError(let code):
            Log.warning("Server error \(code) during background sync", category: .background)
            if code >= 500 {
                // Server errors are retriable
                return .retry
            }
            return .abort

        default:
            Log.error("API error during background sync: \(apiError)", category: .background)
            return .retry
        }
    }

    private func handleNSError(_ nsError: NSError) -> BackgroundSyncRecoveryAction {
        if nsError.code == 404 || (nsError.domain.contains("Gmail") && nsError.code == 404) {
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
