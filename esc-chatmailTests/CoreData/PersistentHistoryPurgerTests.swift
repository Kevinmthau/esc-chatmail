import XCTest
import CoreData
@testable import esc_chatmail

/// Tests the persistent-history purge against the SQLite-backed test stack
/// (in-memory stores don't support history tracking). The purge is exercised
/// directly rather than through the @MainActor DatabaseMaintenanceService
/// singleton, whose stack is the shared on-disk store.
final class PersistentHistoryPurgerTests: XCTestCase {

    private func fetchHistoryTransactionCount(in context: NSManagedObjectContext) throws -> Int {
        try context.performAndWait {
            let request = NSPersistentHistoryChangeRequest.fetchHistory(after: .distantPast)
            let result = try context.execute(request) as? NSPersistentHistoryResult
            return (result?.result as? [NSPersistentHistoryTransaction])?.count ?? 0
        }
    }

    private func saveMessage(id: String, in context: NSManagedObjectContext) throws {
        try context.performAndWait {
            _ = MessageBuilder().withId(id).build(in: context)
            try context.save()
        }
    }

    func testPurge_removesHistoryOlderThanCutoff() throws {
        let stack = TestCoreDataStack(storeKind: .sqlite)
        let context = stack.newBackgroundContext()

        try saveMessage(id: "history-purge-1", in: context)
        try saveMessage(id: "history-purge-2", in: context)
        XCTAssertGreaterThan(try fetchHistoryTransactionCount(in: context), 0)

        let purged = context.performAndWait {
            PersistentHistoryPurger.purgeHistory(olderThan: Date().addingTimeInterval(60), in: context)
        }

        XCTAssertTrue(purged)
        XCTAssertEqual(try fetchHistoryTransactionCount(in: context), 0)
    }

    func testPurge_retainsHistoryNewerThanCutoff() throws {
        let stack = TestCoreDataStack(storeKind: .sqlite)
        let context = stack.newBackgroundContext()

        try saveMessage(id: "history-retain-1", in: context)

        // Default retention cutoff is 7 days in the past; fresh transactions survive.
        let purged = context.performAndWait {
            PersistentHistoryPurger.purgeHistory(in: context)
        }

        XCTAssertTrue(purged)
        XCTAssertGreaterThan(try fetchHistoryTransactionCount(in: context), 0)
    }

    func testPurge_isBestEffortOnStoresWithoutHistorySupport() throws {
        // In-memory stores don't support persistent history: the purge must
        // report failure without throwing, so cleanup can continue.
        let stack = TestCoreDataStack()
        let context = stack.newBackgroundContext()

        try saveMessage(id: "history-unsupported-1", in: context)

        let purged = context.performAndWait {
            PersistentHistoryPurger.purgeHistory(in: context)
        }

        XCTAssertFalse(purged)
    }
}
