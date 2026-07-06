import Foundation

/// Recovery actions for sync/API errors. Produced canonically by
/// `APIError.recoveryAction`; `BackgroundSyncErrorHandler` maps non-APIError
/// inputs onto the same vocabulary.
enum BackgroundSyncRecoveryAction {
    case retry
    case partialSync
    case tokenRefreshAndRetry
    case abort
    case abortNoRetry
}

extension APIError {
    /// Canonical recovery classification for API errors. This is the single
    /// mapping; `RetryStrategy`, `MessageFetcher`, and
    /// `BackgroundSyncErrorHandler` all derive their APIError decisions from
    /// it, so a new case only needs classifying here (exhaustive switch).
    var recoveryAction: BackgroundSyncRecoveryAction {
        switch self {
        case .historyIdExpired:
            return .partialSync
        case .authenticationError:
            // The client's in-loop 401 refresh already ran (or was already
            // consumed) by the time this error escapes, so recovery needs a
            // fresh token from the auth session, not a same-request retry.
            return .tokenRefreshAndRetry
        case .credentialsRevoked:
            return .abortNoRetry
        case .rateLimited, .timeout, .networkError:
            return .retry
        case .serverError(let code):
            return code >= 500 ? .retry : .abort
        case .invalidURL, .invalidData, .decodingError, .notFound:
            // Malformed requests/responses and missing resources repeat their
            // failure on retry.
            return .abort
        }
    }

    /// Whether the same request may be retried as-is, with no other
    /// intervention. Deliberately narrower than "not an abort":
    /// `.partialSync` and `.tokenRefreshAndRetry` recover by doing something
    /// different, so same-request retry loops must not spin on them.
    var isRetriableSameRequest: Bool {
        switch recoveryAction {
        case .retry:
            return true
        case .partialSync, .tokenRefreshAndRetry, .abort, .abortNoRetry:
            return false
        }
    }
}
