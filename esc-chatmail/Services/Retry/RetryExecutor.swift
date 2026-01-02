import Foundation

/// Executes async operations with configurable retry logic using ExponentialBackoff
/// Provides a reusable pattern for retrying transient failures
public struct RetryExecutor<T: Sendable>: Sendable {

    private let maxAttempts: Int
    private let baseDelay: TimeInterval
    private let maxDelay: TimeInterval
    private let shouldRetry: @Sendable (Error, Int) -> Bool

    /// Creates a retry executor with custom configuration
    /// - Parameters:
    ///   - maxAttempts: Maximum number of attempts (default: 3)
    ///   - baseDelay: Initial delay between retries (default: 1.0s)
    ///   - maxDelay: Maximum delay cap (default: 30.0s)
    ///   - shouldRetry: Closure to determine if an error should be retried
    public init(
        maxAttempts: Int = 3,
        baseDelay: TimeInterval = 1.0,
        maxDelay: TimeInterval = 30.0,
        shouldRetry: @escaping @Sendable (Error, Int) -> Bool = { _, _ in true }
    ) {
        self.maxAttempts = maxAttempts
        self.baseDelay = baseDelay
        self.maxDelay = maxDelay
        self.shouldRetry = shouldRetry
    }

    /// Executes an async operation with retry logic
    /// - Parameter operation: The async throwing operation to execute
    /// - Returns: The result of the operation
    /// - Throws: The last error if all retries are exhausted
    public func execute(_ operation: @escaping @Sendable () async throws -> T) async throws -> T {
        var backoff = ExponentialBackoff(
            baseDelay: baseDelay,
            maxDelay: maxDelay
        )
        var lastError: Error?

        for attempt in 0..<maxAttempts {
            do {
                return try await operation()
            } catch {
                lastError = error

                // Check if we should retry this error
                if !shouldRetry(error, attempt) {
                    throw error
                }

                // Don't retry on last attempt
                if attempt >= maxAttempts - 1 {
                    break
                }

                // Wait before retrying
                let delay = backoff.nextDelay()
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
        }

        throw lastError ?? RetryError.exhausted
    }
}

// MARK: - Convenience Initializers

extension RetryExecutor {

    /// Creates a retry executor for network operations
    /// Automatically retries connection errors and timeouts
    public static func network(
        maxAttempts: Int = 3,
        baseDelay: TimeInterval = 1.0,
        maxDelay: TimeInterval = 10.0
    ) -> RetryExecutor {
        RetryExecutor(
            maxAttempts: maxAttempts,
            baseDelay: baseDelay,
            maxDelay: maxDelay,
            shouldRetry: { error, _ in
                isRetryableNetworkError(error)
            }
        )
    }

    /// Creates a retry executor for API operations
    /// Retries network errors but not authentication or not-found errors
    public static func api(
        maxAttempts: Int = 3,
        baseDelay: TimeInterval = 1.0,
        maxDelay: TimeInterval = 10.0
    ) -> RetryExecutor {
        RetryExecutor(
            maxAttempts: maxAttempts,
            baseDelay: baseDelay,
            maxDelay: maxDelay,
            shouldRetry: { error, _ in
                // Don't retry API-specific non-retryable errors
                if let apiError = error as? APIError {
                    switch apiError {
                    case .authenticationError, .notFound:
                        return false
                    default:
                        return true
                    }
                }
                // Retry network errors
                return isRetryableNetworkError(error)
            }
        )
    }
}

// MARK: - Error Classification

extension RetryExecutor {

    /// Checks if an error is a retryable network error
    private static func isRetryableNetworkError(_ error: Error) -> Bool {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet,
                 .networkConnectionLost,
                 .timedOut,
                 .cannotFindHost,
                 .cannotConnectToHost,
                 .dnsLookupFailed,
                 .secureConnectionFailed:
                return true
            default:
                return false
            }
        }

        // Check for POSIX errors
        let nsError = error as NSError
        if nsError.domain == NSPOSIXErrorDomain {
            // ECONNRESET, ETIMEDOUT, etc.
            return true
        }

        return false
    }
}

// MARK: - Retry Errors

/// Errors specific to the retry mechanism
public enum RetryError: Error, LocalizedError {
    case exhausted

    public var errorDescription: String? {
        switch self {
        case .exhausted:
            return "All retry attempts exhausted"
        }
    }
}
