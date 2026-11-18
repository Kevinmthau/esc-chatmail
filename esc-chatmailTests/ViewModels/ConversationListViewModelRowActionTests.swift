import XCTest
import CoreData
@testable import esc_chatmail

/// The list view model's archive and spam entry points and the rows they mark as leaving the
/// list (`ConversationListViewModel.conversationIDsLeavingList`): a row's single-conversation
/// actions (`archiveConversation(withID:)`, `reportSpamConversation(withID:)`), the Mac's batch
/// ones (`archiveConversations(withIDs:)`, `reportSpamConversations(withIDs:)`) and Select
/// mode's; and the list check the swipe's question asks (`listsConversation(withID:)`).
///
/// The view model gets a `MessageActions` over this suite's stack, with a
/// `MockPendingActionsManager`, for its own actions and its selection service's alike, so what
/// an action does to the store and what it queues for Gmail are both read here. Fixtures,
/// saves and reads go through the main-queue context of `MainQueueMessageActionsCoreDataStack`,
/// as in `ConversationSelectionServiceTests`.
///
/// HONEST SCOPE: that an entry point leaves out a row already leaving the list, so nothing
/// runs twice for one row, is not tested. Run twice, every action here finds the store already
/// changed (`MessageActions.isAlreadyApplied`) and queues nothing more, so a second run cannot
/// be told from none.
@MainActor
final class ConversationListViewModelRowActionTests: XCTestCase {
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
        _ = LabelBuilder().inbox().build(in: viewContext)
        _ = LabelBuilder().spam().build(in: viewContext)
    }

    override func tearDown() {
        // Stops what `onAppear(in:)` started (launch repairs, change observation, the deferred
        // setup), as the Mac sidebar suites do; harmless where a test never called it.
        viewModel.onDisappear(preservePreviewRepair: false)
        viewModel = nil
        pendingActionsManager = nil
        viewContext = nil
        stack = nil
        super.tearDown()
    }

    // MARK: - A row's actions

    /// Revert-check: deleting `beginLeavingList` from
    /// `ConversationListViewModel.reportSpamConversation(withID:)`'s guard fails the first
    /// assertion; deleting the `then:` completion that ends it fails the wait.
    func testReportSpamConversation_queuesReportSpamAndMarksTheRowLeavingWhileItRuns() async throws {
        let alice = try makeConversationWithMessage(name: "Alice", messageID: "alice-1")

        viewModel.reportSpamConversation(withID: alice.objectID)

        XCTAssertEqual(viewModel.conversationIDsLeavingList, [alice.objectID])
        await waitUntilNothingIsLeaving()
        let queued = await pendingActionsManager.queuedConversationActions
        XCTAssertEqual(queued.count, 1)
        XCTAssertEqual(queued.first?.type, .reportSpam)
        XCTAssertEqual(queued.first?.messageIds ?? [], ["alice-1"])
    }

    /// The single-conversation action leaves a conversation with no messages as it is; the
    /// batch action archives it. A row's swipe uses the single one on both platforms, for its
    /// Archive and its Report Spam alike.
    ///
    /// Revert-check: replacing `messageActions.reportSpamConversation(conversation:)` with
    /// `messageActions.reportSpamConversations(conversations: [conversation])` in
    /// `ConversationListViewModel.reportSpamConversation(withID:)` makes this fail: the empty
    /// conversation is archived.
    func testReportSpamConversation_conversationWithNoMessages_isLeftAsItIs() async throws {
        let empty = makeConversation(name: "Empty")
        try saveViewContext()

        viewModel.reportSpamConversation(withID: empty.objectID)

        await waitUntilNothingIsLeaving()
        viewContext.refresh(empty, mergeChanges: false)
        XCTAssertNil(empty.archivedAt)
        let queued = await pendingActionsManager.queuedConversationActions
        XCTAssertTrue(queued.isEmpty)
    }

    /// Revert-check: deleting `beginLeavingList` from
    /// `ConversationListViewModel.archiveConversation(withID:)`'s guard fails the first
    /// assertion.
    func testArchiveConversation_queuesArchiveAndMarksTheRowLeavingWhileItRuns() async throws {
        let alice = try makeConversationWithMessage(name: "Alice", messageID: "alice-1")

        viewModel.archiveConversation(withID: alice.objectID)

        XCTAssertEqual(viewModel.conversationIDsLeavingList, [alice.objectID])
        await waitUntilNothingIsLeaving()
        let queued = await pendingActionsManager.queuedConversationActions
        XCTAssertEqual(queued.map(\.type), [.archiveConversation])
    }

    // MARK: - The Mac's batch actions and Select mode

    /// Revert-check: calling `selectionService.reportSpamConversations(withIDs:)` without
    /// `beginLeavingList` in `ConversationListViewModel.reportSpamConversations(withIDs:)`
    /// fails the first assertion; deleting the completion that ends it fails the wait.
    func testReportSpamConversationsWithIDs_marksTheRowsLeavingUntilTheBatchReturns() async throws {
        let alice = try makeConversationWithMessage(name: "Alice", messageID: "alice-1")
        let bob = try makeConversationWithMessage(name: "Bob", messageID: "bob-1")

        viewModel.reportSpamConversations(withIDs: [alice.objectID, bob.objectID])

        XCTAssertEqual(viewModel.conversationIDsLeavingList, [alice.objectID, bob.objectID])
        await waitUntilNothingIsLeaving()
        let queued = await pendingActionsManager.queuedConversationActions
        XCTAssertEqual(queued.map(\.type), [.reportSpam])
        XCTAssertEqual(Set(queued.flatMap(\.messageIds)), ["alice-1", "bob-1"])
    }

    /// A batch that resolves nothing runs nothing, and must still end its rows' leaving, or
    /// they would stay dimmed and swipe nothing until the list is made again.
    ///
    /// Revert-check: deleting the `completion?()` in `ConversationSelectionService
    /// .performBatchAction`'s empty guard makes this fail.
    func testArchiveConversationsWithIDs_nothingResolves_endsTheLeavingAtOnce() throws {
        let gone = makeConversation(name: "Gone")
        try saveViewContext()
        let goneID = gone.objectID
        viewContext.delete(gone)
        try saveViewContext()

        viewModel.archiveConversations(withIDs: [goneID])

        XCTAssertTrue(viewModel.conversationIDsLeavingList.isEmpty)
    }

    /// Revert-check: deleting `beginLeavingList` from
    /// `ConversationListViewModel.reportSpamSelectedConversations()` fails the first assertion.
    func testReportSpamSelectedConversations_marksTheSelectedRowsLeavingUntilTheBatchReturns() async throws {
        let alice = try makeConversationWithMessage(name: "Alice", messageID: "alice-1")
        viewModel.toggleSelectionMode()
        viewModel.toggleSelection(for: alice.objectID)

        viewModel.reportSpamSelectedConversations()

        XCTAssertEqual(viewModel.conversationIDsLeavingList, [alice.objectID])
        await waitUntilNothingIsLeaving()
        let queued = await pendingActionsManager.queuedConversationActions
        XCTAssertEqual(queued.map(\.type), [.reportSpam])
    }

    // MARK: - The question's list check

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

    /// A saved conversation with one message (the INBOX and SPAM labels come from `setUp`).
    private func makeConversationWithMessage(name: String, messageID: String) throws -> Conversation {
        let conversation = makeConversation(name: name)
        _ = MessageBuilder().withId(messageID).inConversation(conversation).build(in: viewContext)
        try saveViewContext()
        return conversation
    }

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

    private func waitUntilNothingIsLeaving(file: StaticString = #filePath, line: UInt = #line) async {
        await waitUntil(file: file, line: line) { [viewModel] in
            viewModel?.conversationIDsLeavingList.isEmpty == true
        }
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
