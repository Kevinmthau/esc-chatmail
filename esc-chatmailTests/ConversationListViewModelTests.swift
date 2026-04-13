import XCTest
import CoreData
import Combine
@testable import esc_chatmail

@MainActor
final class ConversationListViewModelTests: XCTestCase {
    private var stack: TestCoreDataStack!
    private var context: NSManagedObjectContext!

    override func setUp() {
        super.setUp()
        stack = TestCoreDataStack()
        context = stack.viewContext
    }

    override func tearDown() {
        context = nil
        stack = nil
        super.tearDown()
    }

    func testRefreshConversations_recomputesWhenDebouncedSearchUpdates() async throws {
        let alice = ConversationBuilder()
            .withDisplayName("Alice")
            .withSnippet("hello")
            .visible()
            .withLastMessageDate(Date(timeIntervalSince1970: 300))
            .build(in: context)
        let bob = ConversationBuilder()
            .withDisplayName("Bob")
            .withSnippet("project update")
            .visible()
            .withLastMessageDate(Date(timeIntervalSince1970: 200))
            .build(in: context)
        try context.save()

        let viewModel = ConversationListViewModel(
            searchService: ConversationSearchService(debounceInterval: 10_000_000)
        )

        viewModel.refreshConversations([alice, bob])
        XCTAssertEqual(filteredConversationIDs(in: viewModel), [alice.objectID, bob.objectID])

        viewModel.searchText = "bob"
        XCTAssertEqual(filteredConversationIDs(in: viewModel), [alice.objectID, bob.objectID])

        await waitForFilteredConversationIDs([bob.objectID], in: viewModel)

        viewModel.searchText = ""
        await waitForFilteredConversationIDs([alice.objectID, bob.objectID], in: viewModel)
    }

    func testApplyConversationChanges_updatesSnippetAndUnreadWithoutDisturbingUnrelatedItems() throws {
        let alice = makeConversation(name: "Alice", snippet: "alpha", date: 300)
        let bob = makeConversation(name: "Bob", snippet: "beta", date: 200)
        let carol = makeConversation(name: "Carol", snippet: "gamma", date: 100)
        try context.save()

        let viewModel = ConversationListViewModel()
        viewModel.refreshConversations([alice, bob, carol])
        let initialItems = viewModel.filteredConversationItems

        bob.snippet = "updated beta"
        bob.inboxUnreadCount = 3
        viewModel.applyConversationChanges(updatedConversations: [bob])

        XCTAssertEqual(filteredConversationIDs(in: viewModel), [alice.objectID, bob.objectID, carol.objectID])
        XCTAssertEqual(viewModel.filteredConversationItems[1].snapshot.snippet, "updated beta")
        XCTAssertEqual(viewModel.filteredConversationItems[1].snapshot.inboxUnreadCount, 3)
        XCTAssertEqual(viewModel.filteredConversationItems[0], initialItems[0])
        XCTAssertEqual(viewModel.filteredConversationItems[2], initialItems[2])
        XCTAssertNotEqual(viewModel.filteredConversationItems[1], initialItems[1])
    }

    func testApplyConversationChanges_movesConversationToTopAfterNewMessage() throws {
        let alice = makeConversation(name: "Alice", snippet: "alpha", date: 300)
        let bob = makeConversation(name: "Bob", snippet: "beta", date: 200)
        let carol = makeConversation(name: "Carol", snippet: "gamma", date: 100)
        try context.save()

        let viewModel = ConversationListViewModel()
        viewModel.refreshConversations([alice, bob, carol])

        bob.lastMessageDate = Date(timeIntervalSince1970: 400)
        bob.snippet = "newest message"
        viewModel.applyConversationChanges(updatedConversations: [bob])

        XCTAssertEqual(filteredConversationIDs(in: viewModel), [bob.objectID, alice.objectID, carol.objectID])
    }

    func testApplyConversationChanges_reordersForPinAndUnpin() throws {
        let alice = makeConversation(name: "Alice", snippet: "alpha", date: 300)
        let bob = makeConversation(name: "Bob", snippet: "beta", date: 200)
        try context.save()

        let viewModel = ConversationListViewModel()
        viewModel.refreshConversations([alice, bob])

        bob.pinned = true
        viewModel.applyConversationChanges(updatedConversations: [bob])
        XCTAssertEqual(filteredConversationIDs(in: viewModel), [bob.objectID, alice.objectID])

        bob.pinned = false
        viewModel.applyConversationChanges(updatedConversations: [bob])
        XCTAssertEqual(filteredConversationIDs(in: viewModel), [alice.objectID, bob.objectID])
    }

    func testApplyConversationChanges_handlesArchiveAndUnarchive() throws {
        let alice = makeConversation(name: "Alice", snippet: "alpha", date: 300)
        let bob = makeConversation(name: "Bob", snippet: "beta", date: 200)
        try context.save()

        let viewModel = ConversationListViewModel()
        viewModel.refreshConversations([alice, bob])

        bob.archivedAt = Date(timeIntervalSince1970: 500)
        viewModel.applyConversationChanges(updatedConversations: [bob])
        XCTAssertEqual(filteredConversationIDs(in: viewModel), [alice.objectID])

        bob.archivedAt = nil
        bob.lastMessageDate = Date(timeIntervalSince1970: 400)
        viewModel.applyConversationChanges(updatedConversations: [bob])
        XCTAssertEqual(filteredConversationIDs(in: viewModel), [bob.objectID, alice.objectID])
    }

    func testApplyConversationChanges_handlesDeleteWithoutDisturbingUnrelatedRows() throws {
        let alice = makeConversation(name: "Alice", snippet: "alpha", date: 300)
        let bob = makeConversation(name: "Bob", snippet: "beta", date: 200)
        let carol = makeConversation(name: "Carol", snippet: "gamma", date: 100)
        try context.save()

        let viewModel = ConversationListViewModel()
        viewModel.refreshConversations([alice, bob, carol])
        let initialItems = viewModel.filteredConversationItems

        viewModel.applyConversationChanges(deletedIDs: [bob.objectID])

        XCTAssertEqual(filteredConversationIDs(in: viewModel), [alice.objectID, carol.objectID])
        XCTAssertEqual(viewModel.filteredConversationItems[0], initialItems[0])
        XCTAssertEqual(viewModel.filteredConversationItems[1], initialItems[2])
    }

    private func waitForFilteredConversationIDs(
        _ expectedIDs: [NSManagedObjectID],
        in viewModel: ConversationListViewModel,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        if filteredConversationIDs(in: viewModel) == expectedIDs {
            return
        }

        let expectation = expectation(description: "filtered conversations updated")
        var cancellable: AnyCancellable?
        cancellable = viewModel.$filteredConversationItems
            .sink { items in
                guard items.map(\.id) == expectedIDs else { return }
                expectation.fulfill()
                cancellable?.cancel()
            }

        await fulfillment(of: [expectation], timeout: 1.0)
        XCTAssertEqual(filteredConversationIDs(in: viewModel), expectedIDs, file: file, line: line)
    }

    private func makeConversation(name: String, snippet: String, date: TimeInterval) -> Conversation {
        ConversationBuilder()
            .withDisplayName(name)
            .withSnippet(snippet)
            .visible()
            .withLastMessageDate(Date(timeIntervalSince1970: date))
            .build(in: context)
    }

    private func filteredConversationIDs(in viewModel: ConversationListViewModel) -> [NSManagedObjectID] {
        viewModel.filteredConversationItems.map(\.id)
    }
}
