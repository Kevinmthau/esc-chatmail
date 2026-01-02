import Foundation

/// Typed errors for file system operations
/// Provides structured error information for better handling and recovery
public enum FileSystemError: LocalizedError {

    /// Directory creation failed
    case directoryCreationFailed(URL, Error)

    /// File write operation failed
    case fileWriteFailed(URL, Error)

    /// File read operation failed
    case fileReadFailed(URL, Error)

    /// File deletion failed
    case fileDeleteFailed(URL, Error)

    /// Device storage is full
    case diskFull

    /// Permission denied for the operation
    case permissionDenied(URL)

    /// File or directory not found
    case fileNotFound(URL)

    /// Generic file system error
    case unknown(Error)

    // MARK: - LocalizedError

    public var errorDescription: String? {
        switch self {
        case .directoryCreationFailed(let url, _):
            return "Failed to create directory: \(url.lastPathComponent)"
        case .fileWriteFailed(let url, _):
            return "Failed to write file: \(url.lastPathComponent)"
        case .fileReadFailed(let url, _):
            return "Failed to read file: \(url.lastPathComponent)"
        case .fileDeleteFailed(let url, _):
            return "Failed to delete file: \(url.lastPathComponent)"
        case .diskFull:
            return "Device storage is full"
        case .permissionDenied(let url):
            return "Permission denied: \(url.lastPathComponent)"
        case .fileNotFound(let url):
            return "File not found: \(url.lastPathComponent)"
        case .unknown(let error):
            return "File system error: \(error.localizedDescription)"
        }
    }

    public var recoverySuggestion: String? {
        switch self {
        case .directoryCreationFailed:
            return "Check that the parent directory exists and you have write permissions"
        case .fileWriteFailed:
            return "Ensure sufficient storage space and write permissions"
        case .fileReadFailed:
            return "Verify the file exists and is accessible"
        case .fileDeleteFailed:
            return "Check file permissions and that the file is not in use"
        case .diskFull:
            return "Free up storage space on your device"
        case .permissionDenied:
            return "Check app permissions in Settings"
        case .fileNotFound:
            return "The file may have been moved or deleted"
        case .unknown:
            return nil
        }
    }

    // MARK: - Underlying Error

    /// The underlying system error, if available
    public var underlyingError: Error? {
        switch self {
        case .directoryCreationFailed(_, let error),
             .fileWriteFailed(_, let error),
             .fileReadFailed(_, let error),
             .fileDeleteFailed(_, let error),
             .unknown(let error):
            return error
        case .diskFull, .permissionDenied, .fileNotFound:
            return nil
        }
    }

    // MARK: - Recovery Classification

    /// Whether this error might succeed on retry
    public var isTransient: Bool {
        switch self {
        case .diskFull, .permissionDenied:
            return false  // Requires user action
        case .directoryCreationFailed, .fileWriteFailed, .fileReadFailed, .fileDeleteFailed:
            return true   // May succeed on retry (file lock released, etc.)
        case .fileNotFound:
            return false  // File won't appear on retry
        case .unknown:
            return true   // Assume retryable
        }
    }

    /// Whether the error requires user intervention
    public var requiresUserAction: Bool {
        switch self {
        case .diskFull, .permissionDenied:
            return true
        default:
            return false
        }
    }
}
