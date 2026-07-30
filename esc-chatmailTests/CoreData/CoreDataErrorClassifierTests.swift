import XCTest
import CoreData
@testable import esc_chatmail

final class CoreDataErrorClassifierTests: XCTestCase {

    // MARK: - isRecoverableError

    func testIsRecoverableError_timeoutWithinAttempts_returnsTrue() {
        let error = NSError(domain: NSCocoaErrorDomain, code: NSPersistentStoreTimeoutError)
        XCTAssertTrue(CoreDataErrorClassifier.isRecoverableError(error, currentAttempts: 0, maxAttempts: 3))
    }

    func testIsRecoverableError_saveConflictsWithinAttempts_returnsTrue() {
        let error = NSError(domain: NSCocoaErrorDomain, code: NSPersistentStoreSaveConflictsError)
        XCTAssertTrue(CoreDataErrorClassifier.isRecoverableError(error, currentAttempts: 1, maxAttempts: 3))
    }

    func testIsRecoverableError_attemptsExhausted_returnsFalse() {
        let error = NSError(domain: NSCocoaErrorDomain, code: NSPersistentStoreTimeoutError)
        XCTAssertFalse(CoreDataErrorClassifier.isRecoverableError(error, currentAttempts: 3, maxAttempts: 3))
    }

    func testIsRecoverableError_unrelatedError_returnsFalse() {
        let error = NSError(domain: NSCocoaErrorDomain, code: NSValidationMissingMandatoryPropertyError)
        XCTAssertFalse(CoreDataErrorClassifier.isRecoverableError(error, currentAttempts: 0, maxAttempts: 3))
    }

    // MARK: - isMigrationError

    func testIsMigrationError_migrationError_returnsTrue() {
        let codes = [
            NSMigrationError,
            NSMigrationConstraintViolationError,
            NSMigrationCancelledError,
            NSMigrationMissingSourceModelError,
            NSPersistentStoreIncompatibleVersionHashError
        ]
        for code in codes {
            let error = NSError(domain: NSCocoaErrorDomain, code: code)
            XCTAssertTrue(CoreDataErrorClassifier.isMigrationError(error), "Expected code \(code) to be classified as migration")
        }
    }

    /// A version-hash mismatch is deterministic (the store's hashes match no
    /// bundled model), so it must never be classified retryable: retries can't
    /// fix it and only delayed the same migration-recovery outcome.
    func testIsRecoverableError_incompatibleVersionHash_returnsFalse() {
        let error = NSError(domain: NSCocoaErrorDomain, code: NSPersistentStoreIncompatibleVersionHashError)
        XCTAssertFalse(CoreDataErrorClassifier.isRecoverableError(error, currentAttempts: 0, maxAttempts: 3))
    }

    func testRecommendedAction_incompatibleVersionHash_returnsMigrationRecoveryImmediately() {
        let error = NSError(domain: NSCocoaErrorDomain, code: NSPersistentStoreIncompatibleVersionHashError)
        let action = CoreDataErrorClassifier.recommendedAction(for: error, currentAttempts: 0, maxAttempts: 3)
        guard case .migrationRecovery = action else {
            return XCTFail("Expected .migrationRecovery on first attempt (no pointless retries), got \(action)")
        }
    }

    func testIsMigrationError_nonMigrationError_returnsFalse() {
        let error = NSError(domain: NSCocoaErrorDomain, code: NSManagedObjectValidationError)
        XCTAssertFalse(CoreDataErrorClassifier.isMigrationError(error))
    }

    // MARK: - isTransientError

    func testIsTransientError_constraintMerge_returnsTrue() {
        let error = NSError(domain: NSCocoaErrorDomain, code: NSManagedObjectConstraintMergeError)
        XCTAssertTrue(CoreDataErrorClassifier.isTransientError(error))
    }

    func testIsTransientError_saveConflicts_returnsTrue() {
        let error = NSError(domain: NSCocoaErrorDomain, code: NSPersistentStoreSaveConflictsError)
        XCTAssertTrue(CoreDataErrorClassifier.isTransientError(error))
    }

    func testIsTransientError_sqliteDomain_returnsTrue() {
        let error = NSError(domain: NSSQLiteErrorDomain, code: 5)
        XCTAssertTrue(CoreDataErrorClassifier.isTransientError(error))
    }

    func testIsTransientError_otherDomain_returnsFalse() {
        let error = NSError(domain: NSCocoaErrorDomain, code: NSValidationMissingMandatoryPropertyError)
        XCTAssertFalse(CoreDataErrorClassifier.isTransientError(error))
    }

    // MARK: - recommendedAction

    func testRecommendedAction_recoverableTimeout_returnsRetry() {
        let error = NSError(domain: NSCocoaErrorDomain, code: NSPersistentStoreTimeoutError)
        let action = CoreDataErrorClassifier.recommendedAction(for: error, currentAttempts: 0, maxAttempts: 3)
        guard case .retry = action else {
            return XCTFail("Expected .retry, got \(action)")
        }
    }

    func testRecommendedAction_migrationError_returnsMigrationRecovery() {
        let error = NSError(domain: NSCocoaErrorDomain, code: NSMigrationError)
        let action = CoreDataErrorClassifier.recommendedAction(for: error, currentAttempts: 0, maxAttempts: 3)
        guard case .migrationRecovery = action else {
            return XCTFail("Expected .migrationRecovery, got \(action)")
        }
    }

    func testRecommendedAction_unrecoverableNonMigration_returnsStoreReset() {
        let error = NSError(domain: NSCocoaErrorDomain, code: NSValidationMissingMandatoryPropertyError)
        let action = CoreDataErrorClassifier.recommendedAction(for: error, currentAttempts: 0, maxAttempts: 3)
        guard case .storeReset = action else {
            return XCTFail("Expected .storeReset, got \(action)")
        }
    }

    func testRecommendedAction_recoverableButAttemptsExhausted_returnsStoreReset() {
        let error = NSError(domain: NSCocoaErrorDomain, code: NSPersistentStoreTimeoutError)
        let action = CoreDataErrorClassifier.recommendedAction(for: error, currentAttempts: 3, maxAttempts: 3)
        guard case .storeReset = action else {
            return XCTFail("Expected .storeReset (attempts exhausted), got \(action)")
        }
    }
}
