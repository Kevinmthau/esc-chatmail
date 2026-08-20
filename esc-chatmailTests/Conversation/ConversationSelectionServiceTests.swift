import XCTest
import CoreData
import Combine
@testable import esc_chatmail

/// Direct coverage for `ConversationSelectionService`: the pure selection
/// state machine (toggle, select-all, retain, selection mode) plus the
/// synchronous half of the batch actions.
///
/// The batch-action tests drive a real `MessageActions` over
/// `MockPendingActionsManager`, so "the batch call received the resolved
/// conversations" is observed as the queued pending action's message IDs.
/// `TestCoreDataStack`'s `MessageActionsCoreDataStacking` conformance and
/// `MockPendingActionsManager` are declared in `MessageActionsTests.swift`
/// (both target-wide).
@MainActor
final class ConversationSelectionServiceTests: XCTestCase {
    private var stack: TestCoreDataStack!
    private var context: NSManagedObjectContext!
    private var pendingActionsManager: MockPendingActionsManager!
    private var service: ConversationSelectionService!
    private var cancellables: Set<AnyCancellable>!

    override func setUp() {
        super.setUp()
        stack = TestCoreDataStack()
        context = stack.viewContext
        pendingActionsManager = MockPendingActionsManager()
        let messageActions = MessageActions(
            coreDataStack: stack,
            pendingActionsManager: pendingActionsManager,
            rollupMutationSerializer: ConversationRollupMutationSerializer(),
            syncRunCoordinator: SyncRunCoordinator()
        )
        service = ConversationSelectionService(
            messageActions: messageActions,
            viewContext: context
        )
        cancellables = []
    }

    override func tearDown() {
        cancellables = nil
        service = nil
        pendingActionsManager = nil
        context = nil
        stack = nil
        super.tearDown()
    }

    // MARK: - Defaults

    // Revert-check: ConversationSelectionService's `isSelecting = false` /
    // empty `selectedConversationIDs` defaults. HONEST SCOPE: pins the
    // initial state only; any constructor that started in selection mode
    // or pre-selected rows fails it.
    func testInitialState_selectionModeOffAndNoSelection() {
        XCTAssertFalse(service.isSelecting)
        XCTAssertTrue(service.selectedConversationIDs.isEmpty)
    }

    // MARK: - Toggle

    // Revert-check: ConversationSelectionService.toggleSelection(for:)'s
    // insert branch — an unselected identifier must join the selection.
    func testToggleSelection_unselectedIdentifier_addsItToSelection() throws {
        let alice = makeConversation(name: "Alice")
        try stack.saveViewContext()

        service.toggleSelection(for: alice.objectID)

        XCTAssertEqual(service.selectedConversationIDs, [alice.objectID])
    }

    // Revert-check: ConversationSelectionService.toggleSelection(for:)'s
    // remove branch — toggling a selected identifier must drop only it.
    func testToggleSelection_selectedIdentifier_removesItFromSelection() throws {
        let alice = makeConversation(name: "Alice")
        let bob = makeConversation(name: "Bob")
        try stack.saveViewContext()
        service.toggleSelection(for: alice.objectID)
        service.toggleSelection(for: bob.objectID)

        service.toggleSelection(for: alice.objectID)

        XCTAssertEqual(service.selectedConversationIDs, [bob.objectID])
    }

    // MARK: - Select all

    // Revert-check: ConversationSelectionService.selectAll(conversationIDs:)'s
    // select branch — a partial selection selects every given identifier.
    func testSelectAll_partialSelection_selectsAllGivenIdentifiers() throws {
        let alice = makeConversation(name: "Alice")
        let bob = makeConversation(name: "Bob")
        try stack.saveViewContext()
        service.toggleSelection(for: alice.objectID)

        service.selectAll(conversationIDs: [alice.objectID, bob.objectID])

        XCTAssertEqual(service.selectedConversationIDs, [alice.objectID, bob.objectID])
    }

    // Revert-check: ConversationSelectionService.selectAll(conversationIDs:)'s
    // clear branch — when everything given is already selected, the toggle
    // deselects.
    func testSelectAll_selectionEqualsGivenIdentifiers_clearsSelection() throws {
        let alice = makeConversation(name: "Alice")
        let bob = makeConversation(name: "Bob")
        try stack.saveViewContext()
        service.selectAll(conversationIDs: [alice.objectID, bob.objectID])

        service.selectAll(conversationIDs: [alice.objectID, bob.objectID])

        XCTAssertTrue(service.selectedConversationIDs.isEmpty)
    }

    // Revert-check: the `selectedConversationIDs == Set(conversationIDs)`
    // set-equality comparison in ConversationSelectionService.selectAll.
    // Reverting to the old count-equality toggle treats a stale selection of
    // the same size as "all selected" and clears it, leaving the selection
    // empty instead of matching the visible rows.
    func testSelectAll_staleSelectionOfEqualCount_selectsGivenRowsInsteadOfClearing() throws {
        let alice = makeConversation(name: "Alice")
        let bob = makeConversation(name: "Bob")
        let carol = makeConversation(name: "Carol")
        try stack.saveViewContext()
        // Stale state: two selected rows, of which only Bob is still among
        // the visible identifiers handed to selectAll. (Production keeps the
        // selection a subset of visible rows via retainSelection(within:);
        // this test bypasses that reconciliation on purpose to pin the
        // toggle's own semantics.)
        service.toggleSelection(for: alice.objectID)
        service.toggleSelection(for: bob.objectID)

        service.selectAll(conversationIDs: [bob.objectID, carol.objectID])

        XCTAssertEqual(service.selectedConversationIDs, [bob.objectID, carol.objectID])
    }

    // MARK: - Selection mode

    // Revert-check: the `selectedConversationIDs.removeAll()` on exit inside
    // ConversationSelectionService.toggleSelectionMode — leaving selection
    // mode must not leak the previous selection into the next session.
    func testToggleSelectionMode_exitingSelectionMode_clearsSelection() throws {
        let alice = makeConversation(name: "Alice")
        try stack.saveViewContext()
        service.toggleSelectionMode()
        XCTAssertTrue(service.isSelecting)
        service.toggleSelection(for: alice.objectID)

        service.toggleSelectionMode()

        XCTAssertFalse(service.isSelecting)
        XCTAssertTrue(service.selectedConversationIDs.isEmpty)
    }

    // MARK: - Retain within visible rows

    // Revert-check: the `formIntersection` in
    // ConversationSelectionService.retainSelection(within:) — a selected row
    // missing from the visible set must leave the selection.
    func testRetainSelection_selectionContainsHiddenRow_intersectsWithVisibleIDs() throws {
        let alice = makeConversation(name: "Alice")
        let bob = makeConversation(name: "Bob")
        let carol = makeConversation(name: "Carol")
        try stack.saveViewContext()
        service.toggleSelection(for: alice.objectID)
        service.toggleSelection(for: bob.objectID)

        service.retainSelection(within: [bob.objectID, carol.objectID])

        XCTAssertEqual(service.selectedConversationIDs, [bob.objectID])
    }

    // Revert-check: the `isSubset` fast-path guard in
    // ConversationSelectionService.retainSelection(within:). Without it the
    // unconditional `formIntersection` mutates the `@Published` set (willSet
    // fires even when the value is unchanged), so the no-op call below would
    // emit and the zero-emissions assertion fails.
    func testRetainSelection_selectionAlreadySubsetOfVisible_doesNotRepublishSelection() throws {
        let alice = makeConversation(name: "Alice")
        let bob = makeConversation(name: "Bob")
        try stack.saveViewContext()
        service.toggleSelection(for: alice.objectID)

        var emissions = 0
        service.$selectedConversationIDs
            .dropFirst() // skip the replay of the current value
            .sink { _ in emissions += 1 }
            .store(in: &cancellables)

        service.retainSelection(within: [alice.objectID, bob.objectID])
        XCTAssertEqual(emissions, 0)

        // A visible set that actually drops a row still publishes once.
        service.retainSelection(within: [bob.objectID])
        XCTAssertEqual(emissions, 1)
        XCTAssertTrue(service.selectedConversationIDs.isEmpty)
    }

    // MARK: - Batch actions

    // Revert-check: ConversationSelectionService.performBatchAction — it must
    // resolve the selected identifiers BEFORE clearing the selection, and
    // clear synchronously. Clearing first would resolve an empty array and
    // queue nothing (the bounded wait below times out); clearing only after
    // the async batch would fail the immediate empty-selection assertions.
    func testArchiveSelectedConversations_resolvesSelectionThenClearsSynchronouslyAndQueuesOneBatchAction() async throws {
        _ = LabelBuilder().inbox().build(in: context)
        let alice = makeConversation(name: "Alice")
        let bob = makeConversation(name: "Bob")
        _ = MessageBuilder().withId("alice-1").inConversation(alice).build(in: context)
        _ = MessageBuilder().withId("bob-1").inConversation(bob).build(in: context)
        try stack.saveViewContext()

        service.toggleSelectionMode()
        service.toggleSelection(for: alice.objectID)
        service.toggleSelection(for: bob.objectID)

        service.archiveSelectedConversations()

        // Instant UI feedback: cleared before the async batch runs.
        XCTAssertTrue(service.selectedConversationIDs.isEmpty)
        XCTAssertFalse(service.isSelecting)

        await waitUntil { [pendingActionsManager] in
            await pendingActionsManager?.queuedConversationActions.isEmpty == false
        }
        let queued = await pendingActionsManager.queuedConversationActions
        XCTAssertEqual(queued.count, 1)
        XCTAssertEqual(queued.first?.type, .archiveConversation)
        XCTAssertEqual(Set(queued.first?.messageIds ?? []), ["alice-1", "bob-1"])
    }

    // Revert-check: reportSpamSelectedConversations' `.reportSpam` routing
    // through ConversationSelectionService.performBatchAction — the shared
    // template must dispatch the spam batch, not the archive one, and clear
    // the selection synchronously like its twin.
    func testReportSpamSelectedConversations_clearsSynchronouslyAndQueuesReportSpamAction() async throws {
        let alice = makeConversation(name: "Alice")
        _ = MessageBuilder().withId("alice-1").inConversation(alice).build(in: context)
        try stack.saveViewContext()

        service.toggleSelectionMode()
        service.toggleSelection(for: alice.objectID)

        service.reportSpamSelectedConversations()

        XCTAssertTrue(service.selectedConversationIDs.isEmpty)
        XCTAssertFalse(service.isSelecting)

        await waitUntil { [pendingActionsManager] in
            await pendingActionsManager?.queuedConversationActions.isEmpty == false
        }
        let queued = await pendingActionsManager.queuedConversationActions
        XCTAssertEqual(queued.count, 1)
        XCTAssertEqual(queued.first?.type, .reportSpam)
        XCTAssertEqual(queued.first?.messageIds, ["alice-1"])
    }

    // Revert-check: the `guard !conversations.isEmpty` in
    // ConversationSelectionService.performBatchAction — it must bail before
    // the clear, so an empty batch leaves selection mode untouched.
    func testArchiveSelectedConversations_emptySelection_keepsSelectionModeActive() {
        service.toggleSelectionMode()
        XCTAssertTrue(service.isSelecting)

        service.archiveSelectedConversations()

        XCTAssertTrue(service.isSelecting)
    }

    // MARK: - Helpers

    /// createdAt shields the message-light fixtures from the stranded-shell
    /// sweep, mirroring ConversationListViewModelTests' fixture helper.
    private func makeConversation(name: String) -> Conversation {
        ConversationBuilder()
            .withDisplayName(name)
            .visible()
            .withLastMessageDate(Date())
            .withCreatedAt(Date())
            .build(in: context)
    }

    /// Deadline-poll wait copied from ChatViewModelTests (async-condition
    /// variant, needed here to read the mock actor's queue).
    private func waitUntil(
        timeout: TimeInterval = 2.0,
        pollIntervalNanoseconds: UInt64 = 20_000_000,
        file: StaticString = #filePath,
        line: UInt = #line,
        condition: @escaping () async -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)

        while Date() < deadline {
            if await condition() {
                return
            }
            try? await Task.sleep(nanoseconds: pollIntervalNanoseconds)
        }

        XCTFail("Timed out waiting for condition", file: file, line: line)
    }
}
