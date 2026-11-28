import XCTest
import CoreData
@testable import esc_chatmail

/// Fixtures, saves, and assertions go through a main-queue context from
/// `TestCoreDataStack.makeMainQueueViewContext()`, never `stack.viewContext`,
/// which is private-queue. The test bodies use it directly, so `@MainActor` on
/// the class is what puts those accesses on-queue; see that helper for what the
/// private-queue shape races.
///
/// `AccountPersister` works on the background context each test hands it, so
/// this moves only the seed fixture.
///
/// HONEST SCOPE: no test here can reproduce that race on demand. With
/// `-com.apple.CoreData.ConcurrencyDebug 1` the old shape traps and this shape
/// runs clean.
@MainActor
final class AccountPersisterTests: XCTestCase {
    private var stack: TestCoreDataStack!
    private var sut: MessagePersister!

    override func setUpWithError() throws {
        try super.setUpWithError()
        stack = TestCoreDataStack()
        sut = MessagePersister()
    }

    override func tearDownWithError() throws {
        stack = nil
        sut = nil
        try super.tearDownWithError()
    }

    func testSaveAccount_withoutHistoryIdOnCreate_leavesCursorUnset() async throws {
        let context = stack.newBackgroundContext()
        let profile = GmailProfile(
            emailAddress: "test@example.com",
            messagesTotal: 10,
            threadsTotal: 5,
            historyId: "history-new"
        )

        try await sut.saveAccount(
            profile: profile,
            aliases: ["alias@example.com"],
            in: context,
            saveHistoryId: false
        )

        try await context.perform {
            if context.hasChanges {
                try context.save()
            }
        }

        let savedHistoryId = await fetchAccountHistoryId(email: profile.emailAddress)
        XCTAssertNil(savedHistoryId)
    }

    func testSaveAccount_withoutHistoryIdOnUpdate_preservesExistingCursor() async throws {
        let seedContext = stack.makeMainQueueViewContext()
        _ = AccountBuilder()
            .withEmail("test@example.com")
            .withHistoryId("history-old")
            .build(in: seedContext)
        try seedContext.save()

        let context = stack.newBackgroundContext()
        let profile = GmailProfile(
            emailAddress: "test@example.com",
            messagesTotal: 10,
            threadsTotal: 5,
            historyId: "history-new"
        )

        try await sut.saveAccount(
            profile: profile,
            aliases: ["alias@example.com"],
            in: context,
            saveHistoryId: false
        )

        try await context.perform {
            if context.hasChanges {
                try context.save()
            }
        }

        let savedHistoryId = await fetchAccountHistoryId(email: profile.emailAddress)
        XCTAssertEqual(savedHistoryId, "history-old")
    }

    // Revert-check: `AccountPersister.setAccountHistoryId` throwing
    // `AccountPersisterError.accountMissing`. With the earlier body, which logged
    // "No account found" and returned, nothing is thrown and this test fails.
    func testSetAccountHistoryId_withNoAccountRow_throwsAccountMissingAndStagesNothing() async throws {
        let context = stack.newBackgroundContext()

        var thrown: Error?
        do {
            try await sut.setAccountHistoryId("history-1", in: context)
        } catch {
            thrown = error
        }

        guard case .accountMissing? = thrown as? AccountPersisterError else {
            return XCTFail("Expected AccountPersisterError.accountMissing, got \(String(describing: thrown))")
        }
        let hasChanges = await context.perform { context.hasChanges }
        XCTAssertFalse(hasChanges, "A refused stage must leave the sync context clean")
    }

    // Revert-check: the stager writing `account.historyId` into the caller's
    // context and nothing else; a `save()` inside it would make the second
    // assertion fail, because the store would then carry the cursor.
    func testSetAccountHistoryId_withAccountRow_stagesCursorWithoutSaving() async throws {
        let seedContext = stack.makeMainQueueViewContext()
        _ = AccountBuilder()
            .withEmail("test@example.com")
            .withHistoryId("history-old")
            .build(in: seedContext)
        try seedContext.save()

        let context = stack.newBackgroundContext()
        try await sut.setAccountHistoryId("history-staged", in: context)

        let staged = await context.perform {
            let request: NSFetchRequest<Account> = Account.fetchRequest()
            request.fetchLimit = 1
            return (try? context.fetch(request).first)?.historyId
        }
        XCTAssertEqual(staged, "history-staged")

        let stored = await fetchAccountHistoryId(email: "test@example.com")
        XCTAssertEqual(stored, "history-old", "The cursor commits with the run's save, never with the stager")
    }

    /// A cursor staged at the value the row already has leaves the context
    /// with nothing to save, so a run with no new history commits nothing for
    /// it (architecture review 2026-11, background-energy#4).
    ///
    /// Revert-check: the `guard account.historyId != historyId` in
    /// `AccountPersister.setAccountHistoryId` (the equal assignment marks the
    /// row updated and the context has changes).
    func testSetAccountHistoryId_atTheStoredValue_leavesTheContextUnchanged() async throws {
        let seedContext = stack.makeMainQueueViewContext()
        _ = AccountBuilder()
            .withEmail("test@example.com")
            .withHistoryId("history-same")
            .build(in: seedContext)
        try seedContext.save()

        let context = stack.newBackgroundContext()
        try await sut.setAccountHistoryId("history-same", in: context)
        let unchanged = await context.perform { !context.hasChanges }
        try await sut.setAccountHistoryId("history-next", in: context)
        let changed = await context.perform { context.hasChanges }

        XCTAssertTrue(unchanged, "The cursor it already has is no change")
        XCTAssertTrue(changed, "A cursor that moves is still staged")
    }

    private func fetchAccountHistoryId(email: String) async -> String? {
        let context = stack.newBackgroundContext()
        return await context.perform {
            let request: NSFetchRequest<Account> = Account.fetchRequest()
            request.predicate = NSPredicate(format: "email == %@", email)
            request.fetchLimit = 1
            do {
                return try context.fetch(request).first?.historyId
            } catch {
                return nil
            }
        }
    }
}
