import Foundation

/// Classifies file system errors and recommends recovery actions
/// Based on NSError codes from the Cocoa and POSIX error domains
public enum FileSystemErrorClassifier {

    /// Recommended recovery action for an error
    public enum RecoveryAction: Equatable {
        /// Retry the operation after a delay
        case retry(delay: TimeInterval)
        /// Log the error but continue (graceful degradation)
        case ignore
        /// Propagate the error to the caller
        case fail
        /// Requires user intervention (show alert)
        case userAction(message: String)
    }

    /// Operation types for context-aware classification
    public enum Operation {
        case read
        case write
        case delete
        case createDirectory
    }

    // MARK: - Classification

    /// Classifies an error and recommends a recovery action
    /// - Parameters:
    ///   - error: The error to classify
    ///   - operation: The type of operation that failed
    /// - Returns: Recommended recovery action
    public static func classify(_ error: Error, operation: Operation) -> RecoveryAction {
        let nsError = error as NSError

        // Check for disk full errors
        if isDiskFullError(nsError) {
            return .userAction(message: "Device storage is full. Free up space to continue.")
        }

        // Check for permission errors
        if isPermissionError(nsError) {
            return .fail
        }

        // Check for file busy/locked errors (transient)
        if isFileBusyError(nsError) {
            return .retry(delay: 0.5)
        }

        // Check for file not found
        if isFileNotFoundError(nsError) {
            switch operation {
            case .read:
                return .fail  // Can't read what doesn't exist
            case .delete:
                return .ignore  // Deleting non-existent file is success
            case .write, .createDirectory:
                return .fail  // Parent directory may not exist
            }
        }

        // Default handling based on operation
        switch operation {
        case .read, .createDirectory:
            return .fail
        case .write:
            return .retry(delay: 0.5)
        case .delete:
            return .ignore  // Non-critical cleanup
        }
    }

    /// Creates a typed FileSystemError from a raw error
    /// - Parameters:
    ///   - error: The raw error
    ///   - url: The URL involved in the operation
    ///   - operation: The type of operation
    /// - Returns: A typed FileSystemError
    public static func classify(error: Error, url: URL, operation: Operation) -> FileSystemError {
        let nsError = error as NSError

        if isDiskFullError(nsError) {
            return .diskFull
        }

        if isPermissionError(nsError) {
            return .permissionDenied(url)
        }

        if isFileNotFoundError(nsError) {
            return .fileNotFound(url)
        }

        switch operation {
        case .read:
            return .fileReadFailed(url, error)
        case .write:
            return .fileWriteFailed(url, error)
        case .delete:
            return .fileDeleteFailed(url, error)
        case .createDirectory:
            return .directoryCreationFailed(url, error)
        }
    }

    // MARK: - Error Code Checks

    private static func isDiskFullError(_ nsError: NSError) -> Bool {
        // Cocoa file writing errors
        if nsError.domain == NSCocoaErrorDomain {
            return nsError.code == NSFileWriteOutOfSpaceError
        }

        // POSIX errors
        if nsError.domain == NSPOSIXErrorDomain {
            return nsError.code == ENOSPC || nsError.code == EDQUOT
        }

        return false
    }

    private static func isPermissionError(_ nsError: NSError) -> Bool {
        // Cocoa permission errors
        if nsError.domain == NSCocoaErrorDomain {
            return nsError.code == NSFileWriteNoPermissionError ||
                   nsError.code == NSFileReadNoPermissionError
        }

        // POSIX errors
        if nsError.domain == NSPOSIXErrorDomain {
            return nsError.code == EACCES || nsError.code == EPERM
        }

        return false
    }

    private static func isFileBusyError(_ nsError: NSError) -> Bool {
        // POSIX errors
        if nsError.domain == NSPOSIXErrorDomain {
            return nsError.code == EBUSY || nsError.code == ETXTBSY
        }

        // Cocoa file locking
        if nsError.domain == NSCocoaErrorDomain {
            return nsError.code == NSFileLockingError
        }

        return false
    }

    private static func isFileNotFoundError(_ nsError: NSError) -> Bool {
        // Cocoa file not found
        if nsError.domain == NSCocoaErrorDomain {
            return nsError.code == NSFileNoSuchFileError ||
                   nsError.code == NSFileReadNoSuchFileError
        }

        // POSIX errors
        if nsError.domain == NSPOSIXErrorDomain {
            return nsError.code == ENOENT
        }

        return false
    }
}

// MARK: - Convenience Extensions

extension FileSystemErrorClassifier {

    /// Performs a file operation with error classification and logging
    /// - Parameters:
    ///   - operation: The operation type
    ///   - url: The URL involved
    ///   - action: The closure to execute
    /// - Returns: Whether the operation succeeded
    @discardableResult
    public static func perform(
        _ operation: Operation,
        at url: URL,
        action: () throws -> Void
    ) -> Bool {
        do {
            try action()
            return true
        } catch {
            let recovery = classify(error, operation: operation)

            switch recovery {
            case .ignore:
                // Log at debug level for ignored errors
                Log.debug("File operation \(operation) failed at \(url.lastPathComponent) (ignored)", category: .general)
                return true  // Considered success for caller

            case .fail:
                Log.error("File operation \(operation) failed at \(url.lastPathComponent)", category: .general, error: error)
                return false

            case .userAction(let message):
                Log.error("File operation \(operation) requires user action: \(message)", category: .general, error: error)
                return false

            case .retry:
                // Caller should handle retry logic
                Log.warning("File operation \(operation) failed at \(url.lastPathComponent), may retry", category: .general)
                return false
            }
        }
    }
}
