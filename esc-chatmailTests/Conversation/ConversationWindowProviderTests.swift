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
@MainActor
final class ConversationWindowProviderTests: XCTestCase {
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
        try stack.saveViewContext()

        let pendingMatch = makeConversation(
            name: "Pending",
            snippet: "optimistic",
            date: 2_000
        )
        context.processPendingChanges()
        let savedMatch = try XCTUnwrap(savedMatchCandidate)
        let matchingIDs = Set([pendingMatch.objectID, savedMatch.objectID])

        let window = makeProvider().fetchWindow(
            in: context,
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
        try stack.saveViewContext()

        let window = makeProvider().fetchWindow(
            in: context,
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
        try stack.saveViewContext()

        // Pending re-sort: the update is deliberately unsaved, so the
        // persisted pages still hold Carol at date 100 while her in-memory
        // sort key says she now leads the list.
        carol.lastMessageDate = Date(timeIntervalSince1970: 2_000)
        context.processPendingChanges()

        let newestSaved = try XCTUnwrap(newestSavedCandidate)
        let window = makeProvider().fetchWindow(
            in: context,
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
        try stack.saveViewContext()

        // Unsaved archive: SQLite still holds archivedAt == nil for Bob, so
        // the store predicate alone cannot exclude him.
        bob.archivedAt = Date(timeIntervalSince1970: 500)
        context.processPendingChanges()

        let window = makeProvider().fetchWindow(
            in: context,
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
        try stack.saveViewContext()

        // Unsaved delete: SQLite still returns Bob's row until save.
        context.delete(bob)
        context.processPendingChanges()

        let window = makeProvider().fetchWindow(
            in: context,
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
        try stack.saveViewContext()

        var visibilityChecks = 0
        let window = makeProvider().fetchWindow(
            in: context,
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
            .build(in: context)
    }
}
