import CoreData
import XCTest
@testable import esc_chatmail

/// `CoreDataStack.requireAttachedStore(in:)`, and the reason for it: a read on a coordinator
/// with no store attached answers `[]` and no error.
final class AttachedStoreGuardTests: XCTestCase {
    // HONEST SCOPE: this pins Core Data, not the app. It is why an empty answer from a
    // context nothing has checked cannot be taken for "no rows".
    func testFetch_coordinatorWithNoStore_answersEmptyWithoutAnError() throws {
        let (container, _) = TestCoreDataStack.makeStorelessContainer()
        let context = container.newBackgroundContext()

        let rows = try context.performAndWait {
            try context.fetch(NSFetchRequest<NSDictionary>(entityName: "Message"))
        }

        XCTAssertTrue(container.persistentStoreCoordinator.persistentStores.isEmpty)
        XCTAssertEqual(rows.count, 0)
    }

    func testRequireAttachedStore_coordinatorWithNoStore_throwsStoreNotAttached() {
        let (container, _) = TestCoreDataStack.makeStorelessContainer()
        let context = container.newBackgroundContext()

        let result: Result<Void, Error> = context.performAndWait {
            Result { try CoreDataStack.requireAttachedStore(in: context) }
        }

        XCTAssertThrowsError(try result.get()) { error in
            guard case CoreDataError.storeNotAttached = error else {
                return XCTFail("Expected storeNotAttached, got \(error)")
            }
        }
    }

    // Revert-check: the `CoreDataStack.requireAttachedStore(in:)` call in
    // `DatabaseMaintenanceService.deleteOrphanedAttachments`. Without it the batch delete is
    // sent to a coordinator with no store, which raises NSInternalInconsistencyException and
    // crashes the test host (run 2026-11-24, iOS 27.0 simulator): announce the crash before
    // repeating the revert.
    func testDeleteOrphanedAttachments_coordinatorWithNoStore_throwsBeforeTheBatchDelete() {
        let (container, _) = TestCoreDataStack.makeStorelessContainer()
        let context = container.newBackgroundContext()

        let result: Result<[NSManagedObjectID], Error> = context.performAndWait {
            Result { try DatabaseMaintenanceService.deleteOrphanedAttachments(in: context) }
        }

        XCTAssertThrowsError(try result.get()) { error in
            guard case CoreDataError.storeNotAttached = error else {
                return XCTFail("Expected storeNotAttached, got \(error)")
            }
        }
    }

    func testRequireAttachedStore_loadedStore_passes() {
        let stack = TestCoreDataStack()
        let context = stack.newBackgroundContext()

        let result: Result<Void, Error> = context.performAndWait {
            Result { try CoreDataStack.requireAttachedStore(in: context) }
        }

        XCTAssertNoThrow(try result.get())
    }
}
