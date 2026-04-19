import XCTest
import CoreData
@testable import esc_chatmail

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
        let seedContext = stack.viewContext
        AccountBuilder()
            .withEmail("test@example.com")
            .withHistoryId("history-old")
            .build(in: seedContext)
        try stack.saveViewContext()

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
