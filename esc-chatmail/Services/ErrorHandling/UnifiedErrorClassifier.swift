import Foundation
import CoreData

/// Unified error classification for consistent handling across the app.
///
/// Provides:
/// - Severity levels for logging and alerting
/// - Recovery strategies for automatic retry decisions
/// - User-facing messages for error display
///
/// ## Usage
/// ```swift
/// let classification = UnifiedErrorClassifier.classify(error)
/// switch classification.recoveryStrategy {
/// case .retry(let delay):
///     try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
///     // retry operation
/// case .reauth:
///     // prompt user to sign in again
/// case .abort:
///     // stop and report error
/// case .ignore:
///     // log and continue
/// }
/// ```
enum UnifiedErrorClassifier {

    // MARK: - Error Severity

    enum Severity: Int, Comparable {
        case debug = 0      // Not a real error, just for debugging
        case info = 1       // Informational, normal operation
        case warning = 2    // Potential issue, may need attention
        case error = 3      // Real error, operation failed
        case critical = 4   // Critical error, app stability affected

        static func < (lhs: Severity, rhs: Severity) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
    }

    // MARK: - Recovery Strategy

    enum RecoveryStrategy {
        case retry(delay: TimeInterval)  // Retry after delay
        case reauth                       // User needs to re-authenticate
        case abort                        // Stop operation, report error
        case ignore                       // Log and continue
    }

    // MARK: - Error Category

    enum Category {
        case network        // Network connectivity issues
        case authentication // Auth/token issues
        case rateLimit      // API rate limiting
        case server         // Server-side errors
        case coreData       // Core Data/persistence errors
        case fileSystem     // File I/O errors
        case validation     // Data validation errors
        case unknown        // Unclassified errors
    }

    // MARK: - Classification Result

    struct Classification {
        let severity: Severity
        let category: Category
        let recoveryStrategy: RecoveryStrategy
        let isRetryable: Bool
        let userMessage: String
        let technicalDescription: String

        var shouldAlert: Bool {
            severity >= .error
        }

        var shouldLog: Bool {
            severity >= .warning
        }
    }

    // MARK: - Public API

    /// Classifies an error and returns handling recommendations
    static func classify(_ error: Error) -> Classification {
        // Check for API errors
        if let apiError = error as? APIError {
            return classifyAPIError(apiError)
        }

        // Check for Core Data errors
        if let coreDataError = error as? CoreDataError {
            return classifyCoreDataError(coreDataError)
        }

        // Check for URL errors
        if let urlError = error as? URLError {
            return classifyURLError(urlError)
        }

        // Check for NS errors
        let nsError = error as NSError
        return classifyNSError(nsError)
    }

    // MARK: - API Error Classification

    private static func classifyAPIError(_ error: APIError) -> Classification {
        switch error {
        case .authenticationError:
            return Classification(
                severity: .error,
                category: .authentication,
                recoveryStrategy: .reauth,
                isRetryable: false,
                userMessage: "Your session has expired. Please sign in again.",
                technicalDescription: "Authentication token invalid or expired"
            )

        case .rateLimited:
            return Classification(
                severity: .warning,
                category: .rateLimit,
                recoveryStrategy: .retry(delay: 60),
                isRetryable: true,
                userMessage: "Too many requests. Please wait a moment.",
                technicalDescription: "API rate limit exceeded"
            )

        case .serverError(let code):
            let delay: TimeInterval = code >= 500 && code < 600 ? 30 : 10
            return Classification(
                severity: .error,
                category: .server,
                recoveryStrategy: .retry(delay: delay),
                isRetryable: true,
                userMessage: "Server error. Please try again later.",
                technicalDescription: "Server returned error code \(code)"
            )

        case .timeout:
            return Classification(
                severity: .warning,
                category: .network,
                recoveryStrategy: .retry(delay: 5),
                isRetryable: true,
                userMessage: "Request timed out. Please check your connection.",
                technicalDescription: "Request exceeded timeout limit"
            )

        case .historyIdExpired:
            return Classification(
                severity: .info,
                category: .server,
                recoveryStrategy: .ignore,
                isRetryable: false,
                userMessage: "Syncing mailbox...",
                technicalDescription: "History ID expired, performing recovery sync"
            )

        case .notFound:
            return Classification(
                severity: .warning,
                category: .server,
                recoveryStrategy: .abort,
                isRetryable: false,
                userMessage: "Item not found.",
                technicalDescription: "Requested resource does not exist"
            )

        default:
            return Classification(
                severity: .error,
                category: .unknown,
                recoveryStrategy: .abort,
                isRetryable: false,
                userMessage: "An error occurred. Please try again.",
                technicalDescription: "Unhandled API error: \(error)"
            )
        }
    }

    // MARK: - Core Data Error Classification

    private static func classifyCoreDataError(_ error: CoreDataError) -> Classification {
        switch error {
        case .saveFailed(let underlying):
            let nsError = underlying as NSError
            let isTransient = CoreDataErrorClassifier.isTransientError(nsError)

            return Classification(
                severity: isTransient ? .warning : .error,
                category: .coreData,
                recoveryStrategy: isTransient ? .retry(delay: 0.5) : .abort,
                isRetryable: isTransient,
                userMessage: "Failed to save data.",
                technicalDescription: "Core Data save failed: \(underlying.localizedDescription)"
            )

        case .storeLoadFailed(let underlying):
            return Classification(
                severity: .critical,
                category: .coreData,
                recoveryStrategy: .abort,
                isRetryable: false,
                userMessage: "Failed to load data. Please restart the app.",
                technicalDescription: "Core Data store load failed: \(underlying.localizedDescription)"
            )

        case .migrationFailed(let underlying):
            return Classification(
                severity: .critical,
                category: .coreData,
                recoveryStrategy: .abort,
                isRetryable: false,
                userMessage: "Failed to update data format. Please reinstall the app.",
                technicalDescription: "Core Data migration failed: \(underlying.localizedDescription)"
            )

        case .transientFailure(let underlying):
            return Classification(
                severity: .warning,
                category: .coreData,
                recoveryStrategy: .retry(delay: 0.5),
                isRetryable: true,
                userMessage: "Temporary error. Retrying...",
                technicalDescription: "Transient Core Data failure: \(underlying.localizedDescription)"
            )

        case .persistentFailure(let underlying):
            return Classification(
                severity: .critical,
                category: .coreData,
                recoveryStrategy: .abort,
                isRetryable: false,
                userMessage: "Data storage error. Please restart the app.",
                technicalDescription: "Persistent store failure: \(underlying.localizedDescription)"
            )

        case .stackDestroyed:
            return Classification(
                severity: .critical,
                category: .coreData,
                recoveryStrategy: .abort,
                isRetryable: false,
                userMessage: "Data system unavailable. Please restart the app.",
                technicalDescription: "Core Data stack has been destroyed"
            )

        case .entityCreationFailed(let entityName):
            return Classification(
                severity: .critical,
                category: .coreData,
                recoveryStrategy: .abort,
                isRetryable: false,
                userMessage: "Failed to create data. Please restart the app.",
                technicalDescription: "Failed to create Core Data entity: \(entityName)"
            )
        }
    }

    // MARK: - URL Error Classification

    private static func classifyURLError(_ error: URLError) -> Classification {
        switch error.code {
        case .notConnectedToInternet, .networkConnectionLost:
            return Classification(
                severity: .info,
                category: .network,
                recoveryStrategy: .retry(delay: 5),
                isRetryable: true,
                userMessage: "No internet connection.",
                technicalDescription: "Network unavailable: \(error.code.rawValue)"
            )

        case .timedOut:
            return Classification(
                severity: .warning,
                category: .network,
                recoveryStrategy: .retry(delay: 3),
                isRetryable: true,
                userMessage: "Request timed out.",
                technicalDescription: "URL request timeout"
            )

        case .cannotConnectToHost, .cannotFindHost:
            return Classification(
                severity: .error,
                category: .network,
                recoveryStrategy: .retry(delay: 10),
                isRetryable: true,
                userMessage: "Cannot reach server.",
                technicalDescription: "Host unreachable: \(error.code.rawValue)"
            )

        case .secureConnectionFailed:
            return Classification(
                severity: .error,
                category: .network,
                recoveryStrategy: .abort,
                isRetryable: false,
                userMessage: "Secure connection failed.",
                technicalDescription: "SSL/TLS error"
            )

        default:
            return Classification(
                severity: .warning,
                category: .network,
                recoveryStrategy: .retry(delay: 5),
                isRetryable: true,
                userMessage: "Network error occurred.",
                technicalDescription: "URLError code \(error.code.rawValue)"
            )
        }
    }

    // MARK: - NS Error Classification

    private static func classifyNSError(_ error: NSError) -> Classification {
        // Check for file system errors
        if error.domain == NSCocoaErrorDomain {
            let fileErrorCodes = [
                NSFileNoSuchFileError, NSFileReadNoSuchFileError,
                NSFileWriteNoPermissionError, NSFileWriteOutOfSpaceError
            ]

            if fileErrorCodes.contains(error.code) {
                return Classification(
                    severity: .error,
                    category: .fileSystem,
                    recoveryStrategy: .abort,
                    isRetryable: false,
                    userMessage: "File operation failed.",
                    technicalDescription: "File error \(error.code): \(error.localizedDescription)"
                )
            }
        }

        // Check for SQLite errors
        if error.domain == NSSQLiteErrorDomain {
            if error.code == 5 { // SQLITE_BUSY
                return Classification(
                    severity: .warning,
                    category: .coreData,
                    recoveryStrategy: .retry(delay: 0.5),
                    isRetryable: true,
                    userMessage: "Database busy, retrying...",
                    technicalDescription: "SQLite BUSY"
                )
            }
        }

        // Default classification
        return Classification(
            severity: .error,
            category: .unknown,
            recoveryStrategy: .abort,
            isRetryable: false,
            userMessage: "An unexpected error occurred.",
            technicalDescription: "\(error.domain):\(error.code) - \(error.localizedDescription)"
        )
    }
}
