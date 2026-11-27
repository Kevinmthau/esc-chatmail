import XCTest
import CoreData
@testable import esc_chatmail

/// Fixtures go through a main-queue context from
/// `TestCoreDataStack.makeMainQueueViewContext()`, as `AliasManagerTests` does.
@MainActor
final class SendAsAliasManagerInvalidationTests: XCTestCase {
    private var stack: TestCoreDataStack!
    private var context: NSManagedObjectContext!

    override func setUp() {
        super.setUp()
        stack = TestCoreDataStack()
        context = stack.makeMainQueueViewContext()
    }

    override func tearDown() {
        context = nil
        stack = nil
        super.tearDown()
    }

    /// An `invalidate()` that lands while a load is suspended in Core Data wins, as it
    /// does in `AliasManager`: the load answers its caller, who asked under the old
    /// account, and caches nothing, so the next load reads the store again.
    ///
    /// Revert-check: the `invalidationEpoch` comparison in `SendAsAliasManager.getAliases`
    /// (the suspended load's result is cached, and the next load answers the old
    /// account's address).
    func testInvalidate_whileALoadIsSuspendedInCoreData_cachesNothing() async throws {
        let account = AccountBuilder().withEmail("old@example.com").build(in: context)
        try context.save()
        let manager = SendAsAliasManager()
        let gated = FetchGatingContext(
            gatedEntityName: "Account",
            coordinator: stack.persistentContainer.persistentStoreCoordinator
        )
        let load = Task.detached { await manager.getAliases(from: gated) }
        await gated.waitUntilFetchIsReached()

        await manager.invalidate()
        gated.releaseFetch()
        let loaded = await load.value

        XCTAssertEqual(loaded.map(\.emailAddress), ["old@example.com"], "The load still answers its caller")

        account.email = "new@example.com"
        try context.save()
        let afterwards = await manager.getAliases(from: stack.newBackgroundContext())
        XCTAssertEqual(afterwards.map(\.emailAddress), ["new@example.com"], "The next load reads the store again")
    }
}
