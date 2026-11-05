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

    /// A sync page save fails through `CoreDataStack.saveAsync`, which wraps the error in
    /// `CoreDataError.saveFailed`. A Swift enum bridges to `NSError` with no underlying error, so
    /// the full disk behind it was invisible and the run looked like any other failure.
    /// Revert-check: drop the `CoreDataError.underlyingError` step in
    /// `StorageErrorClassifier.errorChain`.
    func testIsOutOfSpace_seesThroughCoreDataErrorWrapping() {
        let sqliteFull = NSError(
            domain: NSCocoaErrorDomain,
            code: NSFileWriteUnknownError,
            userInfo: [NSSQLiteErrorDomain: NSNumber(value: 13)]
        )
        XCTAssertTrue(StorageErrorClassifier.isOutOfSpace(CoreDataError.saveFailed(sqliteFull)))
        XCTAssertTrue(SyncResourceAbort.isInsufficientStorage(CoreDataError.saveFailed(sqliteFull)))
        XCTAssertTrue(StorageErrorClassifier.isOutOfSpace(
            CoreDataError.persistentFailure(NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC)))
        ))
        XCTAssertFalse(StorageErrorClassifier.isOutOfSpace(
            CoreDataError.saveFailed(NSError(domain: NSCocoaErrorDomain, code: NSValidationMissingMandatoryPropertyError))
        ))
        XCTAssertFalse(StorageErrorClassifier.isOutOfSpace(CoreDataError.entityCreationFailed("Message")))
    }

    func testHTMLSaveResult_classifiesWhyTheBodyIsNotOnDisk() {
        XCTAssertNil(HTMLSaveResult.saved(URL(fileURLWithPath: "/tmp/m.html")).bodyWriteFailure)
        XCTAssertEqual(HTMLSaveResult.boundaryClosed.bodyWriteFailure, .boundaryClosed)
        XCTAssertEqual(
            HTMLSaveResult.writeFailed(NSError(
                domain: NSCocoaErrorDomain,
                code: NSFileWriteOutOfSpaceError,
                userInfo: [NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC))]
            )).bodyWriteFailure,
            .outOfSpace
        )
        XCTAssertEqual(
            HTMLSaveResult.writeFailed(NSError(domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError)).bodyWriteFailure,
            .ioError
        )
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
