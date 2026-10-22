import Foundation
import CoreData

/// Classifies Core Data errors to determine appropriate recovery strategies.
///
/// Deleting the store loses the only copies of queued `PendingAction` and
/// `OutboundSendMutationRecord` rows and of the user's sent attachments, and
/// forces a full re-sync. So `.storeReset` is an allow-list of errors that
/// prove the file is not a usable database, and everything else keeps the
/// store. It used to be the fallback for any error that was neither a timeout
/// nor a migration error, which deleted the store on a full disk, an I/O
/// fault, or a launch before first unlock.
enum CoreDataErrorClassifier {

    /// Checks if an error is recoverable with retry.
    /// - Parameters:
    ///   - error: The NSError to classify
    ///   - currentAttempts: Number of attempts already made
    ///   - maxAttempts: Maximum allowed attempts
    /// - Returns: true if the error may succeed on retry
    static func isRecoverableError(_ error: NSError, currentAttempts: Int, maxAttempts: Int) -> Bool {
        // Check for transient errors that might succeed on retry.
        // NSPersistentStoreIncompatibleVersionHashError is deliberately NOT
        // here: a version-hash mismatch is deterministic — the store's model
        // hashes match no bundled model — so retrying can never succeed and
        // only delayed the same migration-recovery outcome. It classifies as
        // a migration error below.
        let recoverableCodes = [
            NSPersistentStoreTimeoutError,
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
            NSMigrationMissingSourceModelError,
            NSPersistentStoreIncompatibleVersionHashError
        ]
        return migrationCodes.contains(error.code)
    }

    /// True when the store file itself is unreadable as a database:
    /// `NSFileReadCorruptFileError` (259), or `SQLITE_CORRUPT` / `SQLITE_NOTADB`
    /// anywhere in the error chain. The only errors that justify a reset.
    static func isCorruptStoreError(_ error: NSError) -> Bool {
        let wrapsCorruptFileError = StorageErrorClassifier.errorChain(error).contains {
            $0.domain == NSCocoaErrorDomain && $0.code == NSFileReadCorruptFileError
        }
        let sqliteCodes = StorageErrorClassifier.sqlitePrimaryResultCodes(in: error)
        return wrapsCorruptFileError
            || sqliteCodes.contains(StorageErrorClassifier.SQLiteResultCode.corrupt)
            || sqliteCodes.contains(StorageErrorClassifier.SQLiteResultCode.notADatabase)
    }

    /// True when the store may be intact but cannot be opened right now: the
    /// volume is full, an I/O call failed, or the file is unreadable because
    /// of permissions or data protection (a cold BGTask launch before first
    /// unlock reports `NSFileReadNoPermissionError` (257) or `SQLITE_AUTH`).
    /// Checked anywhere in the chain, and ahead of the migration and
    /// corruption checks, so a migration that ran out of space keeps the store.
    static func isStoreTemporarilyUnavailableError(_ error: NSError) -> Bool {
        if StorageErrorClassifier.isOutOfSpace(error) {
            return true
        }

        let unavailableCocoaCodes = [
            NSFileReadNoPermissionError,
            NSFileWriteNoPermissionError,
            NSFileWriteVolumeReadOnlyError
        ]
        let unavailablePOSIXCodes = [EACCES, EPERM, EIO, EROFS].map(Int.init)
        let wrapsUnavailableError = StorageErrorClassifier.errorChain(error).contains { error in
            switch error.domain {
            case NSCocoaErrorDomain:
                return unavailableCocoaCodes.contains(error.code)
            case NSPOSIXErrorDomain:
                return unavailablePOSIXCodes.contains(error.code)
            default:
                return false
            }
        }

        let unavailableSQLiteCodes: Set<Int> = [
            StorageErrorClassifier.SQLiteResultCode.permissionDenied,
            StorageErrorClassifier.SQLiteResultCode.busy,
            StorageErrorClassifier.SQLiteResultCode.locked,
            StorageErrorClassifier.SQLiteResultCode.ioError,
            StorageErrorClassifier.SQLiteResultCode.cannotOpen,
            StorageErrorClassifier.SQLiteResultCode.authorizationDenied
        ]
        return wrapsUnavailableError
            || !StorageErrorClassifier.sqlitePrimaryResultCodes(in: error).isDisjoint(with: unavailableSQLiteCodes)
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
        } else if isStoreTemporarilyUnavailableError(error) {
            return .keepStore
        } else if isMigrationError(error) {
            return .migrationRecovery
        } else if isCorruptStoreError(error) {
            return .storeReset
        } else {
            // Exhausted timeouts and unclassified errors prove nothing about
            // the file, so they keep it too.
            return .keepStore
        }
    }

    /// Possible recovery actions for Core Data errors.
    enum RecoveryAction {
        /// Retry the operation after a delay
        case retry
        /// Attempt migration recovery (backup + delete + reload)
        case migrationRecovery
        /// Back up and delete the store. Only for a store proven corrupt.
        case storeReset
        /// Leave the store on disk and latch a load error the user can retry
        /// (`CoreDataStack.retryLoadAfterFailure()`).
        case keepStore
    }
}
