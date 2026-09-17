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

        let window = makeProvider().fetchWindow(
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

        let window = makeProvider().fetchWindow(
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
        let window = makeProvider().fetchWindow(
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

        let window = makeProvider().fetchWindow(
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

        let window = makeProvider().fetchWindow(
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
        let window = makeProvider().fetchWindow(
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
