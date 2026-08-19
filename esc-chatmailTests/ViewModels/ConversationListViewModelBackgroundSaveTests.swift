import XCTest
import CoreData
import Combine
@testable import esc_chatmail

/// Pins the view model's registration-independent didSaveObjectIDs delivery:
/// background-context saves must reach the conversation list even when the
/// displayed `Conversation` objects are NOT registered in the observed
/// context.
///
/// Production shape: sync saves rollups on a background context, and the view
/// context's automerge only *refreshes* objects still registered there (per
/// the documented contract; some OS versions deliver more). The list holds
/// objectIDs + value snapshots (never the managed objects), so once a row's
/// `Conversation` deallocates, a merge that updates it can produce no
/// `Conversation` in `objectsDidChange` and the row goes stale until relaunch —
/// the missing unread blue dot.
///
/// Automerge is deliberately OFF here: the simulator's automerge can deliver
/// updates for unregistered objects too, which would mask a broken
/// didSaveObjectIDs subscription. With no merge, that subscription is the
/// only possible delivery path, so these tests fail if it regresses.
@MainActor
final class ConversationListViewModelBackgroundSaveTests: XCTestCase {
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

    // Revert-check: ConversationListViewModel.handleSiblingContextSave — automerge is off, so the didSaveObjectIDs subscription is the only path that can refresh this deallocated row.
    func testBackgroundSaveUpdatesUnreadForUnregisteredConversation() async throws {
        let viewModel = makeViewModel()
        var conversationID: NSManagedObjectID!

        try autoreleasepool {
            // createdAt: see makeConversation — shields message-less fixtures
            // from the launch repair's stranded-shell sweep.
            let conversation = ConversationBuilder()
                .withDisplayName("Alice")
                .withSnippet("old snippet")
                .visible()
                .withLastMessageDate(Date(timeIntervalSince1970: 300))
                .withCreatedAt(Date())
                .build(in: context)
            try context.save()
            conversationID = conversation.objectID
            viewModel.onAppear(in: context)
        }

        XCTAssertEqual(viewModel.filteredConversationItems.first?.snapshot.inboxUnreadCount, 0)
        // Bug precondition: the row's Conversation must have deallocated, or
        // the registered-object merge path would mask the delivery gap.
        XCTAssertFalse(
            context.registeredObjects.contains { $0.objectID == conversationID },
            "displayed conversation must be unregistered to exercise the delivery gap"
        )

        let backgroundContext = stack.newBackgroundContext()
        try await backgroundContext.perform {
            let conversation = try XCTUnwrap(
                backgroundContext.existingObject(with: conversationID) as? Conversation
            )
            conversation.inboxUnreadCount = 3
            conversation.snippet = "new mail"
            conversation.lastMessageDate = Date(timeIntervalSince1970: 400)
            try backgroundContext.save()
        }

        await waitUntil {
            viewModel.filteredConversationItems.first?.snapshot.inboxUnreadCount == 3
        }
        XCTAssertEqual(viewModel.filteredConversationItems.first?.snapshot.snippet, "new mail")
    }

    // Revert-check: ConversationListViewModel.handleSiblingContextSave — Carol is outside the loaded window, so only the didSaveObjectIDs pipeline can bring her save into the list.
    func testBackgroundSaveBringsOutsideWindowConversationIntoWindow() async throws {
        let viewModel = makeViewModel(
            windowProvider: ConversationWindowProvider(
                configuration: VirtualScrollConfiguration(
                    visibleItemCount: 1,
                    bufferSize: 0,
                    pageSize: 1,
                    preloadThreshold: 1
                )
            )
        )
        var aliceID: NSManagedObjectID!
        var bobID: NSManagedObjectID!
        var carolID: NSManagedObjectID!

        try autoreleasepool {
            let alice = makeConversation(name: "Alice", snippet: "alpha", date: 300)
            let bob = makeConversation(name: "Bob", snippet: "beta", date: 200)
            let carol = makeConversation(name: "Carol", snippet: "gamma", date: 100)
            try context.save()
            aliceID = alice.objectID
            bobID = bob.objectID
            carolID = carol.objectID
            viewModel.onAppear(in: context)
        }

        XCTAssertEqual(filteredConversationIDs(in: viewModel), [aliceID, bobID])

        // Carol sits outside the loaded window, so she is certainly not
        // registered in the observed context when new mail arrives for her.
        let backgroundContext = stack.newBackgroundContext()
        try await backgroundContext.perform {
            let carol = try XCTUnwrap(
                backgroundContext.existingObject(with: carolID) as? Conversation
            )
            carol.lastMessageDate = Date(timeIntervalSince1970: 400)
            carol.snippet = "newest"
            carol.inboxUnreadCount = 1
            try backgroundContext.save()
        }

        await waitForFilteredConversationIDs([carolID, aliceID], in: viewModel)
        XCTAssertEqual(viewModel.filteredConversationItems.first?.snapshot.inboxUnreadCount, 1)
    }

    // Revert-check: ConversationListViewModel.handleSiblingContextSave — a background delete of an unregistered row reaches the list only through the didSaveObjectIDs pipeline's deleted-ID set.
    func testBackgroundDeleteRemovesRowForUnregisteredConversation() async throws {
        let viewModel = makeViewModel()
        var aliceID: NSManagedObjectID!
        var bobID: NSManagedObjectID!

        try autoreleasepool {
            let alice = makeConversation(name: "Alice", snippet: "alpha", date: 300)
            let bob = makeConversation(name: "Bob", snippet: "beta", date: 200)
            try context.save()
            aliceID = alice.objectID
            bobID = bob.objectID
            viewModel.onAppear(in: context)
        }

        XCTAssertEqual(filteredConversationIDs(in: viewModel), [aliceID, bobID])

        let backgroundContext = stack.newBackgroundContext()
        try await backgroundContext.perform {
            let bob = try backgroundContext.existingObject(with: bobID)
            backgroundContext.delete(bob)
            try backgroundContext.save()
        }

        await waitForFilteredConversationIDs([aliceID], in: viewModel)
    }

    // MARK: - didSaveObjectIDs relevance guard

    func testSaveRelevanceGuard_messageOnlyObjectIDs_areIrrelevant() throws {
        let conversation = ConversationBuilder().visible().build(in: context)
        let message = MessageBuilder().inConversation(conversation).build(in: context)
        try context.save()

        let userInfo: [AnyHashable: Any] = [NSUpdatedObjectIDsKey: Set([message.objectID])]
        XCTAssertFalse(ConversationListViewModel.isRelevantConversationSave(userInfo))
    }

    func testSaveRelevanceGuard_conversationObjectIDs_areRelevantInEverySet() throws {
        let conversation = ConversationBuilder().visible().build(in: context)
        try context.save()

        for key in [NSInsertedObjectIDsKey, NSUpdatedObjectIDsKey, NSDeletedObjectIDsKey] {
            let userInfo: [AnyHashable: Any] = [key: Set([conversation.objectID])]
            XCTAssertTrue(
                ConversationListViewModel.isRelevantConversationSave(userInfo),
                "conversation objectID in \(key) must be relevant"
            )
        }
    }

    func testSaveRelevanceGuard_emptyOrNilUserInfo_isIrrelevant() {
        XCTAssertFalse(ConversationListViewModel.isRelevantConversationSave(nil))
        XCTAssertFalse(ConversationListViewModel.isRelevantConversationSave([:]))
    }

    // MARK: - Helpers

    /// onAppear schedules a deferred contacts-cache load whose filter
    /// callback refetches the whole window from the store — which would
    /// deliver the background save regardless of the didSaveObjectIDs
    /// subscription and mask a regression in it. An empty contact loader
    /// leaves the cache unchanged, so no refetch fires and that
    /// subscription is the only delivery path.
    private func makeViewModel(
        windowProvider: ConversationWindowProvider = ConversationWindowProvider()
    ) -> ConversationListViewModel {
        ConversationListViewModel(
            dependencies: .forTesting(
                stack: stack,
                contactEmailLoader: { _ in [] }
            ),
            windowProvider: windowProvider
        )
    }

    /// createdAt keeps these message-less fixtures inside the stranded-shell
    /// grace period: with test-owned storage the launch repair scheduled by
    /// onAppear(in:) sweeps THIS suite's store, and without createdAt it
    /// would archive every saved conversation that has a lastMessageDate but
    /// no Message rows mid-test.
    private func makeConversation(name: String, snippet: String, date: TimeInterval) -> Conversation {
        ConversationBuilder()
            .withDisplayName(name)
            .withSnippet(snippet)
            .visible()
            .withLastMessageDate(Date(timeIntervalSince1970: date))
            .withCreatedAt(Date())
            .build(in: context)
    }

    private func filteredConversationIDs(in viewModel: ConversationListViewModel) -> [NSManagedObjectID] {
        viewModel.filteredConversationItems.map(\.id)
    }

    private func waitUntil(
        timeout: TimeInterval = 10.0,
        pollIntervalNanoseconds: UInt64 = 50_000_000,
        file: StaticString = #filePath,
        line: UInt = #line,
        condition: @escaping () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)

        while Date() < deadline {
            if condition() {
                return
            }
            try? await Task.sleep(nanoseconds: pollIntervalNanoseconds)
        }

        XCTFail("Timed out waiting for condition", file: file, line: line)
    }

    private func waitForFilteredConversationIDs(
        _ expectedIDs: [NSManagedObjectID],
        in viewModel: ConversationListViewModel,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        await waitUntil(file: file, line: line) {
            self.filteredConversationIDs(in: viewModel) == expectedIDs
        }
        XCTAssertEqual(filteredConversationIDs(in: viewModel), expectedIDs, file: file, line: line)
    }
}
