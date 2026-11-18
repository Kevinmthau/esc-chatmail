import XCTest
import CoreData
@testable import esc_chatmail

/// The list view model's single-conversation Report Spam, the iPhone row swipe's answer
/// (`ConversationListViewModel.reportSpamConversation(withID:)`), and the list check the
/// swipe's question asks (`listsConversation(withID:)`).
///
/// The view model gets a `MessageActions` over this suite's stack, with a
/// `MockPendingActionsManager`, so what the action does to the store and what it queues for
/// Gmail are both read here. Fixtures, saves and reads go through the main-queue context of
/// `MainQueueMessageActionsCoreDataStack`, as in `ConversationSelectionServiceTests`.
@MainActor
final class ConversationListViewModelReportSpamTests: XCTestCase {
    private var stack: TestCoreDataStack!
    private var viewContext: NSManagedObjectContext!
    private var pendingActionsManager: MockPendingActionsManager!
    private var viewModel: ConversationListViewModel!

    override func setUp() {
        super.setUp()
        stack = TestCoreDataStack()
        let messageActionsStack = MainQueueMessageActionsCoreDataStack(wrapping: stack)
        viewContext = messageActionsStack.viewContext
        pendingActionsManager = MockPendingActionsManager()
        let messageActions = MessageActions(
            coreDataStack: messageActionsStack,
            pendingActionsManager: pendingActionsManager,
            rollupMutationSerializer: ConversationRollupMutationSerializer(),
            syncRunCoordinator: SyncRunCoordinator()
        )
        viewModel = ConversationListViewModel(
            dependencies: .forTesting(stack: stack, viewContext: viewContext, messageActions: messageActions)
        )
    }

    override func tearDown() {
        viewModel = nil
        pendingActionsManager = nil
        viewContext = nil
        stack = nil
        super.tearDown()
    }

    /// Revert-check: deleting the `conversationIDsBeingReportedAsSpam.insert(convID)` from
    /// `ConversationListViewModel.reportSpamConversation(withID:)` fails the first assertion;
    /// deleting the `then:` completion that removes it fails the last.
    func testReportSpamConversation_queuesReportSpamAndMarksTheRowWhileItRuns() async throws {
        _ = LabelBuilder().inbox().build(in: viewContext)
        _ = LabelBuilder().spam().build(in: viewContext)
        let alice = makeConversation(name: "Alice")
        _ = MessageBuilder().withId("alice-1").inConversation(alice).build(in: viewContext)
        try saveViewContext()

        viewModel.reportSpamConversation(withID: alice.objectID)

        XCTAssertEqual(viewModel.conversationIDsBeingReportedAsSpam, [alice.objectID])
        await waitUntil { [viewModel] in viewModel?.conversationIDsBeingReportedAsSpam.isEmpty == true }
        let queued = await pendingActionsManager.queuedConversationActions
        XCTAssertEqual(queued.count, 1)
        XCTAssertEqual(queued.first?.type, .reportSpam)
        XCTAssertEqual(queued.first?.messageIds ?? [], ["alice-1"])
        XCTAssertTrue(viewModel.conversationIDsBeingReportedAsSpam.isEmpty)
    }

    /// The single-conversation action leaves a conversation with no messages as it is; the
    /// batch action (`reportSpamConversations(withIDs:)`, the Mac sidebar's) archives it. The
    /// row's Archive is the single one, so its Report Spam must be too.
    ///
    /// Revert-check: replacing `messageActions.reportSpamConversation(conversation:)` with
    /// `messageActions.reportSpamConversations(conversations: [conversation])` in
    /// `ConversationListViewModel.reportSpamConversation(withID:)` makes this fail: the empty
    /// conversation is archived.
    func testReportSpamConversation_conversationWithNoMessages_isLeftAsItIs() async throws {
        _ = LabelBuilder().inbox().build(in: viewContext)
        _ = LabelBuilder().spam().build(in: viewContext)
        let empty = makeConversation(name: "Empty")
        try saveViewContext()

        viewModel.reportSpamConversation(withID: empty.objectID)

        await waitUntil { [viewModel] in viewModel?.conversationIDsBeingReportedAsSpam.isEmpty == true }
        viewContext.refresh(empty, mergeChanges: false)
        XCTAssertNil(empty.archivedAt)
        let queued = await pendingActionsManager.queuedConversationActions
        XCTAssertTrue(queued.isEmpty)
    }

    /// Revert-check: making `ConversationListViewModel.listsConversation(withID:)` return true
    /// makes this fail for the archived conversation, which the list does not show.
    func testListsConversation_isTrueForAListedRowAndFalseForOneTheListDoesNotShow() async throws {
        let alice = makeConversation(name: "Alice")
        let archived = ConversationBuilder()
            .withDisplayName("Archived")
            .archived()
            .withLastMessageDate(Date())
            .withCreatedAt(Date())
            .build(in: viewContext)
        try saveViewContext()

        viewModel.onAppear(in: viewContext)
        await waitUntil { [viewModel] in viewModel?.filteredConversationItems.isEmpty == false }

        XCTAssertTrue(viewModel.listsConversation(withID: alice.objectID))
        XCTAssertFalse(viewModel.listsConversation(withID: archived.objectID))
    }

    // MARK: - Helpers

    /// createdAt shields the message-light fixtures from the stranded-shell sweep, as in
    /// `ConversationSelectionServiceTests`.
    private func makeConversation(name: String) -> Conversation {
        ConversationBuilder()
            .withDisplayName(name)
            .visible()
            .withLastMessageDate(Date())
            .withCreatedAt(Date())
            .build(in: viewContext)
    }

    /// Saves the suite's main-queue context directly; the test body is already on its queue.
    private func saveViewContext() throws {
        guard viewContext.hasChanges else { return }
        try viewContext.save()
    }

    /// Deadline-poll wait copied from `ConversationSelectionServiceTests` (async-condition
    /// variant, to read the mock actor's queue).
    private func waitUntil(
        timeout: TimeInterval = 2.0,
        pollIntervalNanoseconds: UInt64 = 20_000_000,
        file: StaticString = #filePath,
        line: UInt = #line,
        condition: @escaping () async -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)

        while await !condition() {
            guard Date() < deadline else {
                XCTFail("Timed out waiting for condition", file: file, line: line)
                return
            }
            try? await Task.sleep(nanoseconds: pollIntervalNanoseconds)
        }
    }
}
