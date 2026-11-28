import XCTest
import CoreData
@testable import esc_chatmail

/// Direct tests for `ConversationWindowProvider.fetchWindow` — no view model.
/// F31: the filtered-paging path (`fetchFilteredWindow`) pages persisted rows
/// with `includesPendingChanges = false` and hand-merges the context's pending
/// conversations exactly once; these tests pin that merge's insert / update /
/// archive / delete handling and the paging loop's limit stop. The two
/// pending-insert tests moved here from `ConversationListViewModelTests`,
/// which now covers only view-model-routed windowing.
///
/// Every fixture, save, and assertion goes through the suite's `viewContext`, a
/// main-queue context from `TestCoreDataStack.makeMainQueueViewContext()`,
/// never `stack.viewContext`, which is private-queue.
/// `ConversationWindowProvider` is not actor-isolated itself, but it fetches
/// and reads pending objects on whatever context it is given
/// (`ConversationWindowProvider.swift:60`) on the caller's thread — here this
/// `@MainActor` test body, and in production `ConversationListViewModel` on
/// the main-queue view context. Either way the context must be main-queue for
/// those accesses to be on-queue. See that helper for what the private-queue
/// shape races.
///
/// HONEST SCOPE: no test here can reproduce that race on demand. With
/// `-com.apple.CoreData.ConcurrencyDebug 1` the old shape traps and this shape
/// runs clean.
@MainActor
final class ConversationWindowProviderTests: XCTestCase {
    private var stack: TestCoreDataStack!
    private var viewContext: NSManagedObjectContext!

    override func setUp() {
        super.setUp()
        stack = TestCoreDataStack()
        viewContext = stack.makeMainQueueViewContext()
    }

    override func tearDown() {
        viewContext = nil
        stack = nil
        super.tearDown()
    }

    // Revert-check: ConversationWindowProvider.fetchFilteredWindow — its persisted-only paging plus single pending-merge is what keeps the pending row deduplicated without skipping saved candidates.
    func testFilteredPagingMergesPendingConversationOnceWithoutSkippingSavedCandidates() throws {
        var savedMatchCandidate: Conversation?
        for index in 0..<11 {
            let conversation = makeConversation(
                name: "Saved \(index)",
                snippet: "candidate",
                date: TimeInterval(1_000 - index)
            )
            if index == 9 {
                savedMatchCandidate = conversation
            }
        }
        try saveViewContext()

        let pendingMatch = makeConversation(
            name: "Pending",
            snippet: "optimistic",
            date: 2_000
        )
        viewContext.processPendingChanges()
        let savedMatch = try XCTUnwrap(savedMatchCandidate)
        let matchingIDs = Set([pendingMatch.objectID, savedMatch.objectID])

        let window = try makeProvider().fetchWindow(
            in: viewContext,
            limit: 2,
            searchText: "",
            filter: .contacts,
            matchesVisibility: { matchingIDs.contains($0.objectID) }
        )

        XCTAssertEqual(window.map(\.objectID), [pendingMatch.objectID, savedMatch.objectID])
        XCTAssertEqual(Set(window.map(\.objectID)).count, window.count)
    }

    // Revert-check: ConversationWindowProvider.fetchWindow's canMatchCurrentFilter early return — without it the empty contact filter would scan (and page through) every fetched candidate.
    func testContactFilterWithEmptyCacheSkipsCandidateScan() throws {
        for index in 0..<10 {
            _ = makeConversation(
                name: "Other \(index)",
                snippet: "not a contact",
                date: TimeInterval(300 - index)
            )
        }
        try saveViewContext()

        let window = try makeProvider().fetchWindow(
            in: viewContext,
            limit: 2,
            searchText: "",
            filter: .contacts,
            canMatchCurrentFilter: false,
            matchesVisibility: { _ in
                XCTFail("Empty contact filters should not scan fetched candidates")
                return false
            }
        )

        XCTAssertTrue(window.isEmpty)
    }

    // Revert-check: fetchFilteredWindow's pending merge (the
    // pendingVisibleConversations union) — persisted-only paging
    // (includesPendingChanges = false) leaves Carol at her stale persisted
    // position, beyond the rows a limit-2 scan ever reaches, so only the
    // merge can deliver her pending re-sort; dropping it loses the row.
    func testFetchWindow_pendingUpdateMovesRowToTop_mergesRowOnceAtNewPosition() throws {
        var newestSavedCandidate: Conversation?
        for index in 0..<10 {
            let conversation = makeConversation(
                name: "Saved \(index)",
                date: TimeInterval(1_000 - index)
            )
            if index == 0 {
                newestSavedCandidate = conversation
            }
        }
        let carol = makeConversation(name: "Carol", date: 100)
        try saveViewContext()

        // Pending re-sort: the update is deliberately unsaved, so the
        // persisted pages still hold Carol at date 100 while her in-memory
        // sort key says she now leads the list.
        carol.lastMessageDate = Date(timeIntervalSince1970: 2_000)
        viewContext.processPendingChanges()

        let newestSaved = try XCTUnwrap(newestSavedCandidate)
        let window = try makeProvider().fetchWindow(
            in: viewContext,
            limit: 2,
            searchText: "",
            filter: .contacts,
            matchesVisibility: { _ in true }
        )

        XCTAssertEqual(window.map(\.objectID), [carol.objectID, newestSaved.objectID])
        XCTAssertEqual(Set(window.map(\.objectID)).count, window.count)
    }

    // Revert-check: the archivedAt == nil filter on fetchFilteredWindow's
    // pendingVisibleConversations — the persisted page still matches Bob's
    // saved archivedAt == nil state, and only the pending-merge filter keeps
    // his unsaved archive out of the window.
    func testFetchWindow_pendingArchive_excludesRowFromFilteredWindow() throws {
        let alice = makeConversation(name: "Alice", date: 300)
        let bob = makeConversation(name: "Bob", date: 200)
        try saveViewContext()

        // Unsaved archive: SQLite still holds archivedAt == nil for Bob, so
        // the store predicate alone cannot exclude him.
        bob.archivedAt = Date(timeIntervalSince1970: 500)
        viewContext.processPendingChanges()

        let window = try makeProvider().fetchWindow(
            in: viewContext,
            limit: 2,
            searchText: "",
            filter: .contacts,
            matchesVisibility: { _ in true }
        )

        XCTAssertEqual(window.map(\.objectID), [alice.objectID])
    }

    // Revert-check: fetchFilteredWindow's pending deletion handling —
    // context.deletedObjects joins the pending set (excluding Bob from the
    // persisted page SQLite still returns until save) and the !isDeleted
    // filter keeps him out of the merge; reverting either half resurrects
    // the deleted row.
    func testFetchWindow_pendingDelete_excludesRowFromFilteredWindow() throws {
        let alice = makeConversation(name: "Alice", date: 300)
        let bob = makeConversation(name: "Bob", date: 200)
        try saveViewContext()

        // Unsaved delete: SQLite still returns Bob's row until save.
        viewContext.delete(bob)
        viewContext.processPendingChanges()

        let window = try makeProvider().fetchWindow(
            in: viewContext,
            limit: 2,
            searchText: "",
            filter: .contacts,
            matchesVisibility: { _ in true }
        )

        XCTAssertEqual(window.map(\.objectID), [alice.objectID])
    }

    // Revert-check: fetchFilteredWindow's mid-batch limit stop (the
    // `persistedVisibleConversations.count < limit` guard). The returned
    // window survives the guard's removal — the final prefix(limit) still
    // trims — so this pins the scan cost instead: reaching the limit
    // mid-batch must stop evaluating candidates, observed through the
    // matchesVisibility call count.
    func testFetchWindow_limitReachedMidCandidateBatch_stopsScanningCandidates() throws {
        var savedConversations: [Conversation] = []
        for index in 0..<10 {
            savedConversations.append(
                makeConversation(name: "Saved \(index)", date: TimeInterval(1_000 - index))
            )
        }
        try saveViewContext()

        var visibilityChecks = 0
        let window = try makeProvider().fetchWindow(
            in: viewContext,
            limit: 2,
            searchText: "",
            filter: .contacts,
            matchesVisibility: { _ in
                visibilityChecks += 1
                return true
            }
        )

        XCTAssertEqual(
            window.map(\.objectID),
            [savedConversations[0].objectID, savedConversations[1].objectID]
        )
        // limit 2 < candidateBatchSize 10: the third through tenth candidates
        // of the only fetched batch must never be evaluated.
        XCTAssertEqual(visibilityChecks, 2)
    }

    // MARK: - Completeness

    /// A row another context deletes between the window fetch's ID query and the faulting
    /// of its rows is a tombstone, which the window drops, so it comes back one row short
    /// of the limit. That is not the end of the store's rows, and the window must not say
    /// it is: counted from the rows, the list latched "all loaded" and paged no more, and
    /// on the Mac nothing reloads (PR 527's review). The race is made deterministic by
    /// deleting right after the fetch returns (`DeletingAfterFetchContext`), on a SQLite
    /// store, where a deleted row is really gone.
    // Revert-check: `isComplete: candidates.count < limit` in
    // `fetchWindowReportingCompleteness` (counted from the returned rows, the window reads
    // as complete).
    func testWindow_aRowTombstonedDuringTheFetch_isNotTheEndOfTheStore() throws {
        let sqliteStack = TestCoreDataStack(storeKind: .sqlite)
        let setup = sqliteStack.makeMainQueueViewContext()
        let alice = ConversationBuilder().withDisplayName("Alice").visible()
            .withLastMessageDate(Date(timeIntervalSince1970: 300)).build(in: setup)
        let bob = ConversationBuilder().withDisplayName("Bob").visible()
            .withLastMessageDate(Date(timeIntervalSince1970: 200)).build(in: setup)
        _ = ConversationBuilder().withDisplayName("Carol").visible()
            .withLastMessageDate(Date(timeIntervalSince1970: 100)).build(in: setup)
        try setup.save()
        let context = DeletingAfterFetchContext(
            entityName: "Conversation",
            coordinator: sqliteStack.persistentContainer.persistentStoreCoordinator
        )
        context.deleteAfterNextFetch(bob.objectID, through: sqliteStack.newBackgroundContext())

        let window = try ConversationWindowProvider().fetchWindowReportingCompleteness(
            in: context,
            limit: 2,
            searchText: "",
            filter: .all,
            matchesVisibility: { _ in true }
        )

        XCTAssertEqual(window.rows.map(\.objectID), [alice.objectID], "Precondition: Bob came back a tombstone and was dropped")
        XCTAssertFalse(window.isComplete)
    }

    func testWindow_storeShorterThanTheLimit_isComplete() throws {
        let alice = makeConversation(name: "Alice", date: 300)
        try saveViewContext()

        let window = try makeProvider().fetchWindowReportingCompleteness(
            in: viewContext,
            limit: 2,
            searchText: "",
            filter: .all,
            matchesVisibility: { _ in true }
        )

        XCTAssertEqual(window.rows.map(\.objectID), [alice.objectID])
        XCTAssertTrue(window.isComplete)
    }

    /// The filtered scan is complete when it ran out of the store before finding the
    /// limit's worth of visible rows, and not when it found them.
    // Revert-check: the `persistedVisibleConversations.count < limit` term of
    // `fetchFilteredWindow`'s completeness (without it a full filtered window reads as
    // final).
    func testFilteredWindow_completeOnlyWhenTheScanRanOutOfTheStore() throws {
        _ = makeConversation(name: "Alice", snippet: "match", date: 300)
        _ = makeConversation(name: "Bob", snippet: "other", date: 200)
        try saveViewContext()

        let short = try makeProvider().fetchWindowReportingCompleteness(
            in: viewContext,
            limit: 2,
            searchText: "match",
            filter: .all,
            matchesVisibility: { $0.snippet == "match" }
        )
        XCTAssertEqual(short.rows.count, 1)
        XCTAssertTrue(short.isComplete)

        _ = makeConversation(name: "Carol", snippet: "match", date: 100)
        try saveViewContext()
        let full = try makeProvider().fetchWindowReportingCompleteness(
            in: viewContext,
            limit: 2,
            searchText: "match",
            filter: .all,
            matchesVisibility: { $0.snippet == "match" }
        )
        XCTAssertEqual(full.rows.count, 2)
        XCTAssertFalse(full.isComplete)
    }

    // MARK: - Keyset pages

    /// Keyset pages, each started after the previous one's last row, must add up to the
    /// window a full fetch reads, in its order: on a SQLite store, where the keyset term is
    /// SQL for stored rows and is evaluated in memory for the context's pending ones, with
    /// pinned rows, rows sharing a date (ordered by UUID), rows with no date, an unsaved row
    /// that ties with stored ones, and a stored row an unsaved change moved. Both filters
    /// that page by keyset.
    // Revert-check (one at a time, in `SortKey.storePredicateForRowsAfter`): dropping
    // `OR lastMessageDate == nil` loses the dateless rows; `id > %@` as `id >= %@` repeats
    // each page's last row; dropping the `pinned == NO` disjunct stops after the pinned rows.
    func testKeysetPages_addUpToAFullFetch_withPinsDateTiesAndNoDates() throws {
        let sqliteStack = TestCoreDataStack(storeKind: .sqlite)
        let context = sqliteStack.makeMainQueueViewContext()
        func row(_ name: String, date: TimeInterval?, pinned: Bool = false, unread: Int32 = 0) -> Conversation {
            let builder = ConversationBuilder().withDisplayName(name).visible().withUnreadCount(unread)
            if let date { _ = builder.withLastMessageDate(Date(timeIntervalSince1970: date)) }
            if pinned { _ = builder.setPinned() }
            let conversation = builder.build(in: context)
            if date == nil { conversation.lastMessageDate = nil }
            return conversation
        }
        _ = row("Pinned new", date: 500, pinned: true, unread: 1)
        _ = row("Pinned undated", date: nil, pinned: true)
        _ = row("Newest", date: 400, unread: 2)
        for index in 0..<5 {
            _ = row("Tie \(index)", date: 300, unread: index.isMultiple(of: 2) ? 1 : 0)
        }
        let moved = row("Moved", date: 200, unread: 1)
        _ = row("Older", date: 100)
        _ = row("Undated a", date: nil, unread: 1)
        _ = row("Undated b", date: nil)
        _ = row("Archived", date: 450)
        let archived = try XCTUnwrap(
            context.registeredObjects.compactMap { $0 as? Conversation }.first { $0.displayName == "Archived" }
        )
        archived.archivedAt = Date()
        try context.save()
        _ = row("Unsaved tie", date: 300, unread: 1)
        moved.lastMessageDate = Date(timeIntervalSince1970: 300)
        context.processPendingChanges()

        let provider = ConversationWindowProvider()
        for filter in [ConversationFilter.all, .unread] {
            let visible: (Conversation) -> Bool = { filter == .unread ? $0.inboxUnreadCount > 0 : true }
            let full = try provider.fetchWindowReportingCompleteness(
                in: context, limit: 100, searchText: "", filter: filter, matchesVisibility: visible
            )
            XCTAssertTrue(full.isComplete, "\(filter)")
            XCTAssertTrue(provider.pagesByKeyset(searchText: "", filter: filter))

            // Several page sizes, so that a page boundary falls on a pinned row, inside a
            // run of equal dates, and between dated and dateless rows.
            for pageSize in 1...3 {
                var paged = try provider.fetchWindowReportingCompleteness(
                    in: context, limit: pageSize, searchText: "", filter: filter, matchesVisibility: visible
                ).rows
                var isComplete = false
                var pages = 0
                while !isComplete, let last = paged.last, pages < 30 {
                    let page = try provider.fetchPage(
                        in: context,
                        after: ConversationListItem.SortKey(conversation: last),
                        limit: pageSize,
                        filter: filter,
                        matchesVisibility: visible
                    )
                    paged += page.rows
                    isComplete = page.isComplete
                    pages += 1
                }

                XCTAssertTrue(isComplete, "\(filter), pages of \(pageSize): the pages reached the end")
                XCTAssertEqual(
                    paged.map { $0.displayName ?? "" },
                    full.rows.map { $0.displayName ?? "" },
                    "\(filter), pages of \(pageSize)"
                )
            }
        }
    }

    /// A search and the contact filters re-check rows in memory, so the store's next rows
    /// are not their next rows: they keep the full reload.
    // Revert-check: `pagesByKeyset` answering true for a search (the search's pages would
    // then be read without its predicate).
    func testPagesByKeyset_onlyForExactStorePredicates() {
        let provider = ConversationWindowProvider()

        XCTAssertTrue(provider.pagesByKeyset(searchText: "", filter: .all))
        XCTAssertTrue(provider.pagesByKeyset(searchText: "  ", filter: .unread))
        XCTAssertFalse(provider.pagesByKeyset(searchText: "bob", filter: .all))
        XCTAssertFalse(provider.pagesByKeyset(searchText: "", filter: .contacts))
        XCTAssertFalse(provider.pagesByKeyset(searchText: "", filter: .other))
    }

    // MARK: - Helpers

    /// Small window: `limit * contactFilterCandidateMultiplier` yields a
    /// candidate batch of 10 at limit 2, so ten-and-eleven-row fixtures
    /// exercise batch boundaries without hundreds of rows.
    /// Saves the suite's main-queue context directly; the test body is
    /// already on its queue. `TestCoreDataStack.saveViewContext()` would save
    /// the stack's private-queue context instead (see the type comment).
    private func saveViewContext() throws {
        guard viewContext.hasChanges else { return }
        try viewContext.save()
    }

    private func makeProvider() -> ConversationWindowProvider {
        ConversationWindowProvider(
            configuration: ConversationListWindowConfiguration(
                initialLimit: 2,
                pageSize: 1,
                preloadThreshold: 1,
                contactFilterCandidateMultiplier: 5
            )
        )
    }

    private func makeConversation(
        name: String,
        snippet: String = "snippet",
        date: TimeInterval
    ) -> Conversation {
        ConversationBuilder()
            .withDisplayName(name)
            .withSnippet(snippet)
            .visible()
            .withLastMessageDate(Date(timeIntervalSince1970: date))
            .build(in: viewContext)
    }
}
