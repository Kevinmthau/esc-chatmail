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

    /// Deterministic migration failures used to reach a reset through the
    /// old `.storeReset` fallback. Under the allow-list a code missing from
    /// `isMigrationError` keeps a store that can never open, so launch would
    /// sit on the failure screen for good.
    ///
    /// Revert-check: removing any of these codes from
    /// `CoreDataErrorClassifier.isMigrationError` fails the matching case.
    func testRecommendedAction_deterministicMigrationFailures_returnMigrationRecovery() {
        let cases: [(String, Int)] = [
            ("NSMigrationMissingMappingModelError", NSMigrationMissingMappingModelError),
            ("NSMigrationManagerSourceStoreError", NSMigrationManagerSourceStoreError),
            ("NSMigrationManagerDestinationStoreError", NSMigrationManagerDestinationStoreError),
            ("NSEntityMigrationPolicyError", NSEntityMigrationPolicyError),
            ("NSInferredMappingModelError", NSInferredMappingModelError)
        ]
        for (name, code) in cases {
            let error = NSError(domain: NSCocoaErrorDomain, code: code)
            let action = CoreDataErrorClassifier.recommendedAction(for: error, currentAttempts: 0, maxAttempts: 3)
            guard case .migrationRecovery = action else {
                XCTFail("Expected \(name) to run migration recovery, got \(action)")
                continue
            }
        }
    }

    /// A migration-family failure caused by a full disk still keeps the store.
    func testRecommendedAction_missingMappingModelOnFullDisk_keepsStore() {
        let error = NSError(
            domain: NSCocoaErrorDomain,
            code: NSMigrationMissingMappingModelError,
            userInfo: [NSSQLiteErrorDomain: NSNumber(value: 13)]
        )
        let action = CoreDataErrorClassifier.recommendedAction(for: error, currentAttempts: 0, maxAttempts: 3)
        guard case .keepStore = action else {
            return XCTFail("Expected .keepStore, got \(action)")
        }
    }

    /// An unclassified error proves nothing about the file, so it keeps the
    /// store instead of deleting it.
    ///
    /// Revert-check: making `.storeReset` the fallback again in
    /// `CoreDataErrorClassifier.recommendedAction` fails this.
    func testRecommendedAction_unclassifiedError_keepsStore() {
        let error = NSError(domain: NSCocoaErrorDomain, code: NSValidationMissingMandatoryPropertyError)
        let action = CoreDataErrorClassifier.recommendedAction(for: error, currentAttempts: 0, maxAttempts: 3)
        guard case .keepStore = action else {
            return XCTFail("Expected .keepStore, got \(action)")
        }
    }

    /// A store that kept timing out is busy, not corrupt.
    func testRecommendedAction_timeoutWithAttemptsExhausted_keepsStore() {
        let error = NSError(domain: NSCocoaErrorDomain, code: NSPersistentStoreTimeoutError)
        let action = CoreDataErrorClassifier.recommendedAction(for: error, currentAttempts: 3, maxAttempts: 3)
        guard case .keepStore = action else {
            return XCTFail("Expected .keepStore (attempts exhausted), got \(action)")
        }
    }

    // MARK: - Store reset allow-list

    /// Revert-check: removing any disjunct of
    /// `CoreDataErrorClassifier.isCorruptStoreError` fails the matching case.
    func testRecommendedAction_corruptStore_returnsStoreReset() {
        let cases: [(String, NSError)] = [
            ("NSFileReadCorruptFileError", NSError(domain: NSCocoaErrorDomain, code: NSFileReadCorruptFileError)),
            ("wrapped SQLITE_CORRUPT", Self.coreDataError(code: NSFileReadUnknownError, sqliteCode: 11)),
            ("wrapped SQLITE_NOTADB", Self.coreDataError(code: NSFileReadUnknownError, sqliteCode: 26)),
            ("underlying SQLITE_CORRUPT_INDEX", Self.wrapping(NSError(domain: NSSQLiteErrorDomain, code: 779)))
        ]
        for (name, error) in cases {
            let action = CoreDataErrorClassifier.recommendedAction(for: error, currentAttempts: 0, maxAttempts: 3)
            guard case .storeReset = action else {
                XCTFail("Expected \(name) to reset the store, got \(action)")
                continue
            }
        }
    }

    /// Out of space, I/O, can't-open and data-protection failures, top level
    /// or wrapped, leave a possibly intact store on disk. Each used to fall
    /// through to `.storeReset`, which deleted the store, every queued action
    /// and every sent original on a full or locked device.
    ///
    /// Revert-check: deleting the `isStoreTemporarilyUnavailableError` arm in
    /// `CoreDataErrorClassifier.recommendedAction` sends the out-of-space
    /// migration to migration recovery and the corrupt-beside-full case to a
    /// reset, both of which delete the store.
    func testRecommendedAction_unavailableStore_keepsStore() {
        let cases: [(String, NSError)] = [
            ("NSFileWriteOutOfSpaceError", NSError(domain: NSCocoaErrorDomain, code: NSFileWriteOutOfSpaceError)),
            ("wrapped ENOSPC", Self.wrapping(NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC)))),
            ("wrapped SQLITE_FULL", Self.coreDataError(code: NSFileReadUnknownError, sqliteCode: 13)),
            ("wrapped SQLITE_CANTOPEN", Self.coreDataError(code: NSFileReadUnknownError, sqliteCode: 14)),
            ("wrapped SQLITE_IOERR_READ", Self.coreDataError(code: NSFileReadUnknownError, sqliteCode: 266)),
            ("NSFileReadNoPermissionError", NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoPermissionError)),
            ("wrapped SQLITE_AUTH", Self.wrapping(NSError(domain: NSSQLiteErrorDomain, code: 23))),
            ("migration that ran out of space", Self.coreDataError(code: NSMigrationError, sqliteCode: 13)),
            ("corrupt flag beside a full disk", Self.coreDataError(code: NSFileReadCorruptFileError, sqliteCode: 13))
        ]
        for (name, error) in cases {
            let action = CoreDataErrorClassifier.recommendedAction(for: error, currentAttempts: 0, maxAttempts: 3)
            guard case .keepStore = action else {
                XCTFail("Expected \(name) to keep the store, got \(action)")
                continue
            }
        }
    }

    /// A Core Data error carrying a SQLite result code the way Core Data
    /// reports one: in `userInfo["NSSQLiteErrorDomain"]`.
    private static func coreDataError(code: Int, sqliteCode: Int) -> NSError {
        NSError(
            domain: NSCocoaErrorDomain,
            code: code,
            userInfo: [NSSQLiteErrorDomain: NSNumber(value: sqliteCode)]
        )
    }

    /// An uninformative top-level error whose cause is only in the chain.
    private static func wrapping(_ underlying: NSError) -> NSError {
        NSError(
            domain: NSCocoaErrorDomain,
            code: NSPersistentStoreOperationError,
            userInfo: [NSUnderlyingErrorKey: underlying]
        )
    }
}
