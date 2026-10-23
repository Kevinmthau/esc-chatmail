import XCTest
import CoreData
@testable import esc_chatmail

final class StorageErrorClassifierTests: XCTestCase {

    /// Core Data and SQLite rarely report a full disk at the top level.
    ///
    /// Revert-check: testing only the top-level error in
    /// `StorageErrorClassifier.isOutOfSpace` (instead of `errorChain`) fails
    /// every wrapped case, and dropping `sqlitePrimaryResultCodes` fails the
    /// SQLITE_FULL cases.
    func testIsOutOfSpace_recognizesFullVolumeAnywhereInTheChain() {
        let cases: [(String, NSError)] = [
            ("NSFileWriteOutOfSpaceError", NSError(domain: NSCocoaErrorDomain, code: NSFileWriteOutOfSpaceError)),
            ("ENOSPC", NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC))),
            ("EDQUOT", NSError(domain: NSPOSIXErrorDomain, code: Int(EDQUOT))),
            ("ENOSPC two levels down", Self.wrapping(Self.wrapping(NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC))))),
            ("SQLITE_FULL in Core Data userInfo", NSError(
                domain: NSCocoaErrorDomain,
                code: NSFileReadUnknownError,
                userInfo: [NSSQLiteErrorDomain: NSNumber(value: 13)]
            )),
            ("underlying SQLITE_FULL", Self.wrapping(NSError(domain: NSSQLiteErrorDomain, code: 13))),
            ("ENOSPC among detailed errors", NSError(
                domain: NSCocoaErrorDomain,
                code: NSValidationMultipleErrorsError,
                userInfo: [NSDetailedErrorsKey: [
                    NSError(domain: NSCocoaErrorDomain, code: NSValidationMissingMandatoryPropertyError),
                    NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC))
                ]]
            )),
            ("ENOSPC among multiple underlying errors", NSError(
                domain: NSCocoaErrorDomain,
                code: NSFileWriteUnknownError,
                userInfo: [NSMultipleUnderlyingErrorsKey: [NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC))]]
            ))
        ]
        for (name, error) in cases {
            XCTAssertTrue(StorageErrorClassifier.isOutOfSpace(error), name)
        }
    }

    func testIsOutOfSpace_rejectsOtherStorageFailures() {
        let cases: [(String, Error)] = [
            ("SQLITE_CANTOPEN", NSError(
                domain: NSCocoaErrorDomain,
                code: NSFileReadUnknownError,
                userInfo: [NSSQLiteErrorDomain: NSNumber(value: 14)]
            )),
            ("SQLITE_IOERR", Self.wrapping(NSError(domain: NSSQLiteErrorDomain, code: 10))),
            ("EACCES", NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES))),
            ("unrelated Cocoa error", NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoSuchFileError)),
            ("Swift error", PendingActionError.missingMessageIds)
        ]
        for (name, error) in cases {
            XCTAssertFalse(StorageErrorClassifier.isOutOfSpace(error), name)
        }
    }

    func testSQLitePrimaryResultCodes_masksExtendedCodes() {
        let error = Self.wrapping(NSError(
            domain: NSCocoaErrorDomain,
            code: NSFileReadUnknownError,
            userInfo: [NSSQLiteErrorDomain: NSNumber(value: 778)]
        ))

        XCTAssertEqual(StorageErrorClassifier.sqlitePrimaryResultCodes(in: error), [10])
    }

    private static func wrapping(_ underlying: NSError) -> NSError {
        NSError(
            domain: NSCocoaErrorDomain,
            code: NSPersistentStoreOperationError,
            userInfo: [NSUnderlyingErrorKey: underlying]
        )
    }
}
