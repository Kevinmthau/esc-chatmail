import Foundation
import CoreData

/// Classifies Core Data errors to determine appropriate recovery strategies.
enum CoreDataErrorClassifier {

    /// Checks if an error is recoverable with retry.
    /// - Parameters:
    ///   - error: The NSError to classify
    ///   - currentAttempts: Number of attempts already made
    ///   - maxAttempts: Maximum allowed attempts
    /// - Returns: true if the error may succeed on retry
    static func isRecoverableError(_ error: NSError, currentAttempts: Int, maxAttempts: Int) -> Bool {
        // Check for transient errors that might succeed on retry
        let recoverableCodes = [
            NSPersistentStoreTimeoutError,
            NSPersistentStoreIncompatibleVersionHashError,
            NSPersistentStoreSaveConflictsError
        ]
        return recoverableCodes.contains(error.code) && currentAttempts < maxAttempts
    }

    /// Checks if an error is migration-related.
    /// - Parameter error: The NSError to classify
    /// - Returns: true if the error is related to migration
    static func isMigrationError(_ error: NSError) -> Bool {
        let migrationCodes = [
            NSMigrationError,
            NSMigrationConstraintViolationError,
            NSMigrationCancelledError,
            NSMigrationMissingSourceModelError
        ]
        return migrationCodes.contains(error.code)
    }

    /// Checks if an error is transient and may succeed on retry.
    /// - Parameter error: The NSError to classify
    /// - Returns: true if the error is transient
    static func isTransientError(_ error: NSError) -> Bool {
        // Errors that might succeed on retry
        let transientCodes = [
            NSManagedObjectConstraintMergeError,
            NSPersistentStoreSaveConflictsError,
            NSSQLiteError // SQLite busy errors
        ]
        return transientCodes.contains(error.code) || error.domain == NSSQLiteErrorDomain
    }

    /// Determines the recommended recovery action for an error.
    /// - Parameters:
    ///   - error: The NSError to analyze
    ///   - currentAttempts: Number of attempts already made
    ///   - maxAttempts: Maximum allowed attempts
    /// - Returns: The recommended recovery action
    static func recommendedAction(for error: NSError, currentAttempts: Int, maxAttempts: Int) -> RecoveryAction {
        if isRecoverableError(error, currentAttempts: currentAttempts, maxAttempts: maxAttempts) {
            return .retry
        } else if isMigrationError(error) {
            return .migrationRecovery
        } else {
            return .storeReset
        }
    }

    /// Possible recovery actions for Core Data errors.
    enum RecoveryAction {
        /// Retry the operation after a delay
        case retry
        /// Attempt migration recovery (backup + delete + reload)
        case migrationRecovery
        /// Reset the store entirely (last resort)
        case storeReset
    }
}
