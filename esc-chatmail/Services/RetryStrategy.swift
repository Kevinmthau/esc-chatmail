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

        // Don't retry authentication errors
        if let apiError = error as? APIError {
            switch apiError {
            case .authenticationError, .decodingError, .invalidURL:
                return false
            case .rateLimited, .serverError, .timeout, .networkError:
                return true
            case .historyIdExpired, .notFound:
                return false
            }
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

// MARK: - Request Executor

/// Executes URL requests with retry logic
actor RequestExecutor {
    private let session: URLSession
    private let retryStrategy: RetryStrategy

    init(session: URLSession, retryStrategy: RetryStrategy = NetworkRetryStrategy()) {
        self.session = session
        self.retryStrategy = retryStrategy
    }

    func execute<T: Decodable>(_ request: URLRequest) async throws -> T {
        var lastError: Error?
        var retryDelay = retryStrategy.initialDelay

        for attempt in 0..<retryStrategy.maxRetries {
            do {
                let (data, response) = try await session.data(for: request)

                // Check for HTTP errors
                if let httpResponse = response as? HTTPURLResponse {
                    switch httpResponse.statusCode {
                    case 429:
                        // Rate limited - wait longer
                        let delay = retryDelay * 2
                        Log.warning("Rate limited, waiting \(delay) seconds before retry", category: .api)
                        try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                        retryDelay = min(delay * 2, retryStrategy.maxDelay)
                        continue

                    case 500...599:
                        // Server error - retry with backoff
                        Log.warning("Server error \(httpResponse.statusCode), attempt \(attempt + 1) of \(retryStrategy.maxRetries)", category: .api)
                        if attempt < retryStrategy.maxRetries - 1 {
                            try await Task.sleep(nanoseconds: UInt64(retryDelay * 1_000_000_000))
                            retryDelay = min(retryDelay * 2, retryStrategy.maxDelay)
                            continue
                        }
                        throw APIError.serverError(httpResponse.statusCode)

                    case 401:
                        throw APIError.authenticationError

                    case 200...299:
                        // Handle empty response for void-like operations
                        if data.isEmpty {
                            if let empty = EmptyResponse() as? T {
                                return empty
                            }
                        }

                    default:
                        break
                    }
                }

                return try JSONDecoder().decode(T.self, from: data)

            } catch {
                lastError = error
                Log.error("Request failed (attempt \(attempt + 1)/\(retryStrategy.maxRetries)): \(error.localizedDescription)", category: .api)

                // Check if we should retry
                if !retryStrategy.shouldRetry(error: error, attempt: attempt) {
                    if error is DecodingError {
                        throw APIError.decodingError(error)
                    }
                    throw error
                }

                if attempt < retryStrategy.maxRetries - 1 {
                    Log.info("Retrying in \(retryDelay) seconds...", category: .api)
                    try await Task.sleep(nanoseconds: UInt64(retryDelay * 1_000_000_000))
                    retryDelay = min(retryDelay * 2, retryStrategy.maxDelay)
                }
            }
        }

        throw lastError ?? URLError(.unknown)
    }
}
