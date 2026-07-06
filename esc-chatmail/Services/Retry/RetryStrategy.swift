import Foundation

// MARK: - Retry Strategy Protocol

protocol RetryStrategy: Sendable {
    var maxRetries: Int { get }
    var initialDelay: TimeInterval { get }
    var maxDelay: TimeInterval { get }

    func shouldRetry(error: Error, attempt: Int) -> Bool
    func delay(forAttempt attempt: Int) -> TimeInterval
}

// MARK: - Default Implementation

extension RetryStrategy {
    func delay(forAttempt attempt: Int) -> TimeInterval {
        let delay = initialDelay * pow(2.0, Double(attempt))
        return min(delay, maxDelay)
    }
}

// MARK: - Network Retry Strategy

/// Standard retry strategy for network requests with exponential backoff
struct NetworkRetryStrategy: RetryStrategy {
    let maxRetries: Int
    let initialDelay: TimeInterval
    let maxDelay: TimeInterval

    init(
        maxRetries: Int = NetworkConfig.maxRetries,
        initialDelay: TimeInterval = NetworkConfig.initialRetryDelay,
        maxDelay: TimeInterval = NetworkConfig.maxRetryDelay
    ) {
        self.maxRetries = maxRetries
        self.initialDelay = initialDelay
        self.maxDelay = maxDelay
    }

    func shouldRetry(error: Error, attempt: Int) -> Bool {
        guard attempt < maxRetries else { return false }

        // APIError decisions come from the canonical mapping on the type.
        if let apiError = error as? APIError {
            return apiError.isRetriableSameRequest
        }

        // Retry connection-level errors
        if ConnectionErrorDetector.isConnectionError(error) {
            return true
        }

        // Retry URL errors for transient network issues
        if let urlError = error as? URLError {
            return ConnectionErrorDetector.isRetryableURLError(urlError)
        }

        // Don't retry decoding errors
        if error is DecodingError {
            return false
        }

        return false
    }
}

// MARK: - Connection Error Detection

/// Utility for detecting connection-level errors that may be transient
enum ConnectionErrorDetector {
    /// Checks if an error is a connection-level error that should be retried
    static func isConnectionError(_ error: Error) -> Bool {
        let nsError = error as NSError

        // POSIX errors (connection reset, broken pipe, etc.)
        if nsError.domain == NSPOSIXErrorDomain {
            // ECONNRESET (54), EPIPE (32), ENOTCONN (57), ENETDOWN (50), ENETRESET (52)
            return [32, 50, 52, 54, 57].contains(nsError.code)
        }

        // NSURLError connection-related codes
        if nsError.domain == NSURLErrorDomain {
            switch nsError.code {
            case NSURLErrorNetworkConnectionLost,      // -1005
                 NSURLErrorNotConnectedToInternet,     // -1009
                 NSURLErrorCannotConnectToHost,        // -1004
                 NSURLErrorTimedOut,                   // -1001
                 NSURLErrorSecureConnectionFailed,     // -1200
                 NSURLErrorCannotFindHost,             // -1003
                 NSURLErrorDNSLookupFailed,            // -1006
                 -1022,  // NSURLErrorAppTransportSecurityRequiresSecureConnection
                 -1017,  // NSURLErrorCannotParseResponse
                 -1011,  // NSURLErrorBadServerResponse
                 -997:   // Lost connection before completion
                return true
            default:
                return false
            }
        }

        // Check for QUIC-specific errors in the underlying error
        if let underlyingError = nsError.userInfo[NSUnderlyingErrorKey] as? NSError {
            return isConnectionError(underlyingError)
        }

        return false
    }

    /// Checks if an error proves the request never reached the server, making it safe
    /// to resend even a non-idempotent request. Only connection-establishment failures
    /// (DNS, connect, TLS handshake) qualify; timeouts and dropped connections are
    /// ambiguous because the request may have been delivered before the failure.
    static func isPreTransmissionError(_ error: Error) -> Bool {
        let nsError = error as NSError

        if nsError.domain == NSURLErrorDomain {
            switch nsError.code {
            case NSURLErrorNotConnectedToInternet,
                 NSURLErrorCannotFindHost,
                 NSURLErrorDNSLookupFailed,
                 NSURLErrorCannotConnectToHost,
                 NSURLErrorSecureConnectionFailed:
                return true
            default:
                return false
            }
        }

        // URLSession often wraps the connection failure in a generic error
        if let underlyingError = nsError.userInfo[NSUnderlyingErrorKey] as? NSError {
            return isPreTransmissionError(underlyingError)
        }

        return false
    }

    /// Checks if a URLError is retryable
    static func isRetryableURLError(_ urlError: URLError) -> Bool {
        switch urlError.code {
        case .notConnectedToInternet,
             .networkConnectionLost,
             .timedOut,
             .cannotFindHost,
             .dnsLookupFailed,
             .cannotConnectToHost,
             .secureConnectionFailed:
            return true
        case .unsupportedURL:
            return false
        default:
            // For other URL errors, assume potentially retryable
            return true
        }
    }
}
