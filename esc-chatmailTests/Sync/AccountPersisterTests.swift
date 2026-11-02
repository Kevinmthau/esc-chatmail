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
