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
            .recentlyActive()
            .build(in: context)
        let bob = ConversationBuilder()
            .withDisplayName("Bob")
            .withSnippet("project update")
            .visible()
            .recentlyActive()
            .build(in: context)
        try context.save()

        let viewModel = ConversationListViewModel(
            searchService: ConversationSearchService(debounceInterval: 10_000_000)
        )

        viewModel.refreshConversations([alice, bob])
        XCTAssertEqual(viewModel.filteredConversations.map(\.objectID), [alice.objectID, bob.objectID])

        viewModel.searchText = "bob"
        XCTAssertEqual(viewModel.filteredConversations.map(\.objectID), [alice.objectID, bob.objectID])

        await waitForFilteredConversationIDs([bob.objectID], in: viewModel)

        viewModel.searchText = ""
        await waitForFilteredConversationIDs([alice.objectID, bob.objectID], in: viewModel)
    }

    private func waitForFilteredConversationIDs(
        _ expectedIDs: [NSManagedObjectID],
        in viewModel: ConversationListViewModel,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        if viewModel.filteredConversations.map(\.objectID) == expectedIDs {
            return
        }

        let expectation = expectation(description: "filtered conversations updated")
        var cancellable: AnyCancellable?
        cancellable = viewModel.$filteredConversations
            .sink { conversations in
                guard conversations.map(\.objectID) == expectedIDs else { return }
                expectation.fulfill()
                cancellable?.cancel()
            }

        await fulfillment(of: [expectation], timeout: 1.0)
        XCTAssertEqual(viewModel.filteredConversations.map(\.objectID), expectedIDs, file: file, line: line)
    }
}
