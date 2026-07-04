import XCTest
import CoreData
@testable import esc_chatmail

/// Smoke tests for `TestCoreDataStack`'s opt-in SQLite mode — the scaffolding
/// that history-dependent tests (persistent history purge) build on, since
/// in-memory stores don't support persistent history tracking.
final class TestCoreDataStackSQLiteModeTests: XCTestCase {

    func testSQLiteMode_loadsOnDiskStore() {
        let stack = TestCoreDataStack(storeKind: .sqlite)
        let stores = stack.persistentContainer.persistentStoreCoordinator.persistentStores
        XCTAssertEqual(stores.count, 1)
        XCTAssertEqual(stores.first?.type, NSSQLiteStoreType)
        guard let url = stores.first?.url else {
            return XCTFail("SQLite store should have a file URL")
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    func testSQLiteMode_saveAndFetchRoundTrip() throws {
        let stack = TestCoreDataStack(storeKind: .sqlite)
        let context = stack.viewContext

        try context.performAndWait {
            _ = MessageBuilder().withId("sqlite-smoke-1").build(in: context)
            try context.save()
        }

        try context.performAndWait {
            let request = NSFetchRequest<Message>(entityName: "Message")
            request.predicate = NSPredicate(format: "id == %@", "sqlite-smoke-1")
            let results = try context.fetch(request)
            XCTAssertEqual(results.count, 1)
        }
    }

    func testSQLiteMode_recordsPersistentHistory() throws {
        let stack = TestCoreDataStack(storeKind: .sqlite)
        let context = stack.newBackgroundContext()

        try context.performAndWait {
            _ = MessageBuilder().withId("sqlite-history-1").build(in: context)
            try context.save()
        }

        try context.performAndWait {
            let historyRequest = NSPersistentHistoryChangeRequest.fetchHistory(after: .distantPast)
            let result = try context.execute(historyRequest) as? NSPersistentHistoryResult
            let transactions = result?.result as? [NSPersistentHistoryTransaction]
            XCTAssertFalse(transactions?.isEmpty ?? true, "SQLite mode should record persistent history transactions")
        }
    }

    func testInMemoryMode_remainsDefault() {
        let stack = TestCoreDataStack()
        let stores = stack.persistentContainer.persistentStoreCoordinator.persistentStores
        XCTAssertEqual(stores.first?.type, NSInMemoryStoreType)
    }
}
