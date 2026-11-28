import XCTest
import CoreData
@testable import esc_chatmail

/// How the conversation list fills its window past the first fetch: by keyset pages of the
/// missing rows (`ConversationListViewModel.fillWindowFromStore`), never a reload from the
/// first row, and how it keeps a current window when it appears again. Architecture review
/// 2026-11, conversation-list-ui#3 (scalability step 11).
///
/// What the list asked the store is read from the requests themselves
/// (`FetchRecordingContext`): a page asks for exactly the rows missing, a full reload for
/// the whole window. Every suite store is SQLite, where the keyset term is SQL. Fixtures,
/// saves and assertions go through main-queue contexts, as in
/// `ConversationListViewModelTests`.
@MainActor
final class ConversationListViewModelPagingTests: XCTestCase {
    private var stack: TestCoreDataStack!
    private var viewContext: NSManagedObjectContext!
    private var observed: FetchRecordingContext!

    override func setUp() {
        super.setUp()
        stack = TestCoreDataStack(storeKind: .sqlite)
        viewContext = stack.makeMainQueueViewContext()
        observed = FetchRecordingContext(
            recordedEntityName: "Conversation",
            coordinator: stack.persistentContainer.persistentStoreCoordinator
        )
    }

    override func tearDown() {
        observed = nil
        viewContext = nil
        stack = nil
        super.tearDown()
    }

    // MARK: - Pages

    /// Each page asks for the page's rows and no more, after the window's last row, and the
    /// window stays what a fresh fetch would read. Before, each page raised the limit and
    /// reloaded and re-snapshotted the whole window from its first row.
    // Revert-check: `loadMoreIfNeeded` calling `reloadConversationWindowFromStore()` in
    // place of `fillWindowFromStore()` (the pages ask for 5, 7 and 9 rows).
    func testLoadMore_asksOnlyForThePage_andKeepsAFreshFetchsOrder() throws {
        try makeConversations(count: 10)
        let viewModel = makeViewModel(initialLimit: 3, pageSize: 2)
        viewModel.onAppear(in: observed)
        XCTAssertEqual(viewModel.filteredConversationItems.count, 3)

        for expectedCount in [5, 7, 9] {
            let requestsBefore = observed.executedRequests.count
            let last = try XCTUnwrap(viewModel.filteredConversationItems.last)
            viewModel.loadMoreIfNeeded(currentItem: last)

            let pageRequests = observed.executedRequests.dropFirst(requestsBefore)
            XCTAssertEqual(pageRequests.map(\.fetchLimit), [2], "One request for the page's two rows")
            XCTAssertEqual(viewModel.filteredConversationItems.count, expectedCount)
        }
        XCTAssertEqual(
            viewModel.filteredConversationItems.map(\.id),
            try freshWindow(limit: 9),
            "The paged window is a fresh fetch's prefix"
        )
    }

    /// A page that reaches the store's end completes the window, so paging stops.
    func testLoadMore_lastPage_completesTheWindow() throws {
        try makeConversations(count: 4)
        let viewModel = makeViewModel(initialLimit: 3, pageSize: 2)
        viewModel.onAppear(in: observed)

        let last = try XCTUnwrap(viewModel.filteredConversationItems.last)
        viewModel.loadMoreIfNeeded(currentItem: last)
        XCTAssertEqual(viewModel.filteredConversationItems.count, 4)

        let requestsBefore = observed.executedRequests.count
        let newLast = try XCTUnwrap(viewModel.filteredConversationItems.last)
        viewModel.loadMoreIfNeeded(currentItem: newLast)
        XCTAssertEqual(observed.executedRequests.count, requestsBefore, "A complete window pages no more")
    }

    /// An archive deep in a full window opens one slot, and the backfill asks for that one
    /// row past the window's last, not the whole window again.
    // Revert-check: `backfillConversationWindowIfNeeded` calling
    // `reloadConversationWindowFromStore()` in place of `fillWindowFromStore()` (the
    // backfill asks for the whole window of 4).
    func testBackfillAfterAnArchive_asksOnlyForTheMissingRow() throws {
        try makeConversations(count: 6)
        let viewModel = makeViewModel(initialLimit: 4, pageSize: 2)
        viewModel.onAppear(in: observed)
        let archivedID = viewModel.filteredConversationItems[2].id

        let requestsBefore = observed.executedRequests.count
        let archived = try XCTUnwrap(observed.existingObject(with: archivedID) as? Conversation)
        archived.archivedAt = Date()
        observed.processPendingChanges()

        let backfillRequests = observed.executedRequests.dropFirst(requestsBefore)
        XCTAssertEqual(backfillRequests.map(\.fetchLimit), [1])
        // A full fetch on the list's own context, which sees the unsaved archive.
        XCTAssertEqual(viewModel.filteredConversationItems.map(\.id), try freshWindow(limit: 4, in: observed))
        XCTAssertFalse(viewModel.filteredConversationItems.contains { $0.id == archivedID })
    }

    // MARK: - Appearing again

    /// The iOS list appears again on every pop from a chat. The window it shows is current
    /// (the view model observed every change while hidden), so appearing again reads
    /// nothing; an invalidate-all leaves a reload owed, which the next appearance makes.
    // Revert-check: the `observesAnotherContext || windowReloadOwed` guard in `onAppear`
    // (reloading every time asks for the window again on the second appearance).
    func testOnAppear_againOnTheSameContext_readsNothing_untilAReloadIsOwed() throws {
        try makeConversations(count: 4)
        let viewModel = makeViewModel(initialLimit: 3, pageSize: 2)
        viewModel.onAppear(in: observed)
        let window = viewModel.filteredConversationItems.map(\.id)

        let requestsBefore = observed.executedRequests.count
        viewModel.onAppear(in: observed)
        XCTAssertEqual(observed.executedRequests.count, requestsBefore)
        XCTAssertEqual(viewModel.filteredConversationItems.map(\.id), window)

        observed.reset()
        XCTAssertEqual(viewModel.filteredConversationItems, [], "Precondition: the invalidate-all emptied the window")
        viewModel.onAppear(in: observed)
        XCTAssertEqual(viewModel.filteredConversationItems.map(\.id), window)
    }

    // MARK: - Rows a batch delete removed

    /// The empty-conversation pass removes rows with a batch delete, merged into the list's
    /// context, which reports only the rows the context has registered. A window row whose
    /// object was let go stays on screen; the full reload of every iOS appearance was what
    /// healed it, and the Mac never had that. Now the end of a cleanup run checks the
    /// window against the store.
    // Revert-check: the body of `pruneWindowRowsGoneFromStore` (an empty one leaves the
    // deleted row on screen).
    func testBatchDeletedWindowRow_leavesTheWindowWhenACleanupRunEnds() async throws {
        let notificationCenter = NotificationCenter()
        var ids: [NSManagedObjectID] = []
        let viewModel = makeViewModel(initialLimit: 3, pageSize: 2, notificationCenter: notificationCenter)
        try autoreleasepool {
            ids = try makeConversations(count: 3)
            viewContext.reset()
            viewModel.onAppear(in: viewContext)
        }
        XCTAssertEqual(viewModel.filteredConversationItems.map(\.id), ids)
        let doomedID = ids[1]
        XCTAssertNil(viewContext.registeredObject(for: doomedID), "Precondition: the row's object was let go")

        let background = stack.newBackgroundContext()
        let target = viewContext!
        try background.performAndWait {
            let request = NSBatchDeleteRequest(objectIDs: [doomedID])
            request.resultType = .resultTypeObjectIDs
            let result = try background.execute(request) as? NSBatchDeleteResult
            let deleted = result?.result as? [NSManagedObjectID] ?? []
            XCTAssertEqual(deleted, [doomedID])
            NSManagedObjectContext.mergeChanges(fromRemoteContextSave: [NSDeletedObjectsKey: deleted], into: [target])
        }
        XCTAssertTrue(
            viewModel.filteredConversationItems.contains { $0.id == doomedID },
            "Precondition: the merge did not reach the row"
        )

        notificationCenter.post(name: .conversationCleanupFinished, object: nil)
        await waitUntil { !viewModel.filteredConversationItems.contains { $0.id == doomedID } }
        XCTAssertEqual(viewModel.filteredConversationItems.map(\.id), [ids[0], ids[2]])
    }

    // MARK: - Helpers

    /// `count` saved conversations, newest first in the returned order (the window's).
    @discardableResult
    private func makeConversations(count: Int) throws -> [NSManagedObjectID] {
        let conversations = (0..<count).map { index in
            ConversationBuilder()
                .withDisplayName("Row \(index)")
                .withSnippet("snippet")
                .visible()
                .withLastMessageDate(Date(timeIntervalSince1970: TimeInterval(1_000 - index)))
                .withCreatedAt(Date())
                .build(in: viewContext)
        }
        try viewContext.save()
        return conversations.map(\.objectID)
    }

    /// What a full window fetch reads, on a new context unless one is given.
    private func freshWindow(limit: Int, in context: NSManagedObjectContext? = nil) throws -> [NSManagedObjectID] {
        let fetchContext = context ?? stack.makeMainQueueViewContext()
        return try ConversationWindowProvider().fetchWindow(
            in: fetchContext,
            limit: limit,
            searchText: "",
            filter: .all,
            matchesVisibility: { _ in true }
        ).map(\.objectID)
    }

    private func makeViewModel(
        initialLimit: Int,
        pageSize: Int,
        notificationCenter: NotificationCenter = NotificationCenter()
    ) -> ConversationListViewModel {
        ConversationListViewModel(
            dependencies: .forTesting(
                stack: stack,
                viewContext: viewContext,
                migrationFlags: InMemoryMigrationFlagStore.withConversationListLaunchPassesDone(),
                contactEmailLoader: { _ in [] },
                notificationCenter: notificationCenter
            ),
            windowProvider: ConversationWindowProvider(
                configuration: ConversationListWindowConfiguration(
                    initialLimit: initialLimit,
                    pageSize: pageSize,
                    preloadThreshold: 1,
                    contactFilterCandidateMultiplier: 5
                )
            )
        )
    }

    /// Polls `condition` until it holds or `timeout` elapses (copied from
    /// `ConversationListViewModelTests`).
    private func waitUntil(
        timeout: TimeInterval = 2.0,
        pollIntervalNanoseconds: UInt64 = 20_000_000,
        file: StaticString = #filePath,
        line: UInt = #line,
        condition: @escaping () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)

        while !condition() {
            guard Date() < deadline else {
                XCTFail("Timed out waiting for condition", file: file, line: line)
                return
            }
            try? await Task.sleep(nanoseconds: pollIntervalNanoseconds)
        }
    }
}
