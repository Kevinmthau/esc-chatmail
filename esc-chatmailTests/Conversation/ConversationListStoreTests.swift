import XCTest
import CoreData
@testable import esc_chatmail

/// Direct characterization tests for `ConversationListStore` — no view model.
/// F9 step 1: pin the reducer's ordering, snapshot-refresh, removal-reporting,
/// and trim behavior before the ordered/visible index collapse (F9 step 2).
@MainActor
final class ConversationListStoreTests: XCTestCase {
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

    // Revert-check: ConversationListStore.replaceAll — it must keep the
    // caller's order verbatim (fetchWindow already sorted it) and apply the
    // visibility filter to the incoming window.
    func testReplaceAll_mixedVisibilityWindow_preservesGivenOrderAndDropsNonMatchingRows() throws {
        let alice = makeConversation(name: "Alice", date: 300)
        let bob = makeConversation(name: "Bob", date: 200)
        let carol = makeConversation(name: "Carol", date: 100)
        try stack.saveViewContext()

        var store = ConversationListStore()
        // Deliberately not sort order: the store must not re-sort the window.
        store.replaceAll(with: [bob, alice, carol]) { $0.objectID != carol.objectID }

        XCTAssertEqual(visibleIDs(of: store), [bob.objectID, alice.objectID])
        XCTAssertNil(store.itemsByID[carol.objectID])
        assertStoreIndexesAligned(store)
    }

    // Revert-check: ConversationListStore.applyChanges (upsertConversation's
    // sortKey-change reorder) — a lastMessageDate or pinned change must move
    // the row to its sorted position.
    func testApplyChanges_sortKeyChanges_moveRowToSortedPosition() throws {
        let alice = makeConversation(name: "Alice", date: 300)
        let bob = makeConversation(name: "Bob", date: 200)
        let carol = makeConversation(name: "Carol", date: 100)
        try stack.saveViewContext()

        var store = ConversationListStore()
        store.replaceAll(with: [alice, bob, carol]) { _ in true }

        bob.lastMessageDate = Date(timeIntervalSince1970: 400)
        var removed = applyUpdate(&store, updated: [bob])
        XCTAssertTrue(removed.isEmpty)
        XCTAssertEqual(visibleIDs(of: store), [bob.objectID, alice.objectID, carol.objectID])

        carol.pinned = true
        removed = applyUpdate(&store, updated: [carol])
        XCTAssertTrue(removed.isEmpty)
        XCTAssertEqual(visibleIDs(of: store), [carol.objectID, bob.objectID, alice.objectID])
        assertStoreIndexesAligned(store)
    }

    // Revert-check: ConversationListStore.applyChanges (upsertConversation's
    // in-place visibleItems refresh) — an unchanged sortKey must keep the
    // row's position while replacing its snapshot.
    func testApplyChanges_sortKeyUnchanged_keepsPositionAndRefreshesSnapshot() throws {
        let alice = makeConversation(name: "Alice", date: 300)
        let bob = makeConversation(name: "Bob", date: 200)
        let carol = makeConversation(name: "Carol", date: 100)
        try stack.saveViewContext()

        var store = ConversationListStore()
        store.replaceAll(with: [alice, bob, carol]) { _ in true }
        let initialItems = store.visibleItems

        bob.snippet = "updated beta"
        bob.inboxUnreadCount = 3
        let removed = applyUpdate(&store, updated: [bob])

        XCTAssertTrue(removed.isEmpty)
        XCTAssertEqual(visibleIDs(of: store), [alice.objectID, bob.objectID, carol.objectID])
        XCTAssertEqual(store.visibleItems[1].snapshot.snippet, "updated beta")
        XCTAssertEqual(store.visibleItems[1].snapshot.inboxUnreadCount, 3)
        XCTAssertEqual(store.visibleItems[0], initialItems[0])
        XCTAssertEqual(store.visibleItems[2], initialItems[2])
        XCTAssertNotEqual(store.visibleItems[1], initialItems[1])
        assertStoreIndexesAligned(store)
    }

    // Revert-check: ConversationListStore.applyChanges — a row failing
    // isSourceConversation (archived) must be removed AND reported in the
    // returned set.
    func testApplyChanges_archivedRow_isRemovedAndReported() throws {
        let alice = makeConversation(name: "Alice", date: 300)
        let bob = makeConversation(name: "Bob", date: 200)
        try stack.saveViewContext()

        var store = ConversationListStore()
        store.replaceAll(with: [alice, bob]) { _ in true }

        bob.archivedAt = Date(timeIntervalSince1970: 500)
        let removed = applyUpdate(&store, updated: [bob])

        XCTAssertEqual(removed, [bob.objectID])
        XCTAssertEqual(visibleIDs(of: store), [alice.objectID])
        XCTAssertNil(store.itemsByID[bob.objectID])
        assertStoreIndexesAligned(store)
    }

    // Revert-check: ConversationListStore.applyChanges — deletedIDs must be
    // removed AND reported in the returned set.
    func testApplyChanges_deletedIDs_areRemovedAndReported() throws {
        let alice = makeConversation(name: "Alice", date: 300)
        let bob = makeConversation(name: "Bob", date: 200)
        let carol = makeConversation(name: "Carol", date: 100)
        try stack.saveViewContext()

        var store = ConversationListStore()
        store.replaceAll(with: [alice, bob, carol]) { _ in true }

        let removed = applyUpdate(&store, deleted: [carol.objectID])

        XCTAssertEqual(removed, [carol.objectID])
        XCTAssertEqual(visibleIDs(of: store), [alice.objectID, bob.objectID])
        XCTAssertNil(store.itemsByID[carol.objectID])
        assertStoreIndexesAligned(store)
    }

    // Revert-check: ConversationListStore.applyChanges (upsertConversation's
    // remove-on-visibility-miss path) — a row that stops matching
    // matchesVisibility leaves the store. Characterization: today that
    // removal is NOT reported in the returned set (upsertConversation
    // discards removeConversation's result). That is safe because the view
    // model's publishVisibleItems reconciles the selection against the
    // visible rows via ConversationSelectionService.retainSelection(within:)
    // on every publish, so no caller depends on the report.
    func testApplyChanges_rowStopsMatchingVisibility_isRemovedWithoutBeingReported() throws {
        let alice = makeConversation(name: "Alice", date: 300, unread: 1)
        let bob = makeConversation(name: "Bob", date: 200, unread: 1)
        try stack.saveViewContext()

        let matchesUnread: (Conversation) -> Bool = { $0.inboxUnreadCount > 0 }

        var store = ConversationListStore()
        store.replaceAll(with: [alice, bob], matchesVisibility: matchesUnread)

        bob.inboxUnreadCount = 0
        let removed = applyUpdate(&store, updated: [bob], matchesVisibility: matchesUnread)

        XCTAssertTrue(removed.isEmpty)
        XCTAssertEqual(visibleIDs(of: store), [alice.objectID])
        XCTAssertNil(store.itemsByID[bob.objectID])
        assertStoreIndexesAligned(store)
    }

    // Revert-check: ConversationListStore.trimVisibleItems — it must return
    // exactly the trimmed IDs and drop them from itemsByID, and a window
    // already within the limit must trim nothing.
    func testTrimVisibleItems_overLimit_returnsExactlyTrimmedIDsAndDropsThemFromStore() throws {
        let alice = makeConversation(name: "Alice", date: 400)
        let bob = makeConversation(name: "Bob", date: 300)
        let carol = makeConversation(name: "Carol", date: 200)
        let dave = makeConversation(name: "Dave", date: 100)
        try stack.saveViewContext()

        var store = ConversationListStore()
        store.replaceAll(with: [alice, bob, carol, dave]) { _ in true }

        let trimmed = store.trimVisibleItems(to: 2)

        XCTAssertEqual(trimmed, [carol.objectID, dave.objectID])
        XCTAssertEqual(visibleIDs(of: store), [alice.objectID, bob.objectID])
        XCTAssertNil(store.itemsByID[carol.objectID])
        XCTAssertNil(store.itemsByID[dave.objectID])
        assertStoreIndexesAligned(store)

        XCTAssertTrue(store.trimVisibleItems(to: 2).isEmpty)
        XCTAssertEqual(visibleIDs(of: store), [alice.objectID, bob.objectID])
        assertStoreIndexesAligned(store)
    }

    // Revert-check: ConversationListStore.applyChanges (sortsBefore's UUID
    // tie-break) — equal lastMessageDates fall back to conversation UUID
    // ascending, matching ConversationWindowProvider's NSSortDescriptor order
    // (pinned desc, lastMessageDate desc, id asc).
    func testApplyChanges_equalLastMessageDates_orderFallsBackToConversationUUIDAscending() throws {
        let sharedDate: TimeInterval = 300
        let first = makeConversation(
            name: "First",
            date: sharedDate,
            id: try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000001"))
        )
        let second = makeConversation(
            name: "Second",
            date: sharedDate,
            id: try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000002"))
        )
        let third = makeConversation(
            name: "Third",
            date: sharedDate,
            id: try XCTUnwrap(UUID(uuidString: "FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF"))
        )
        try stack.saveViewContext()

        var store = ConversationListStore()
        // Upsert in shuffled order into an empty store: sorted insertion must
        // land every row at its UUID-ascending position.
        let removed = applyUpdate(&store, updated: [second, third, first])

        XCTAssertTrue(removed.isEmpty)
        XCTAssertEqual(visibleIDs(of: store), [first.objectID, second.objectID, third.objectID])
        assertStoreIndexesAligned(store)
    }

    // Revert-check: ConversationListStore.applyChanges /
    // ConversationListStore.trimVisibleItems — after any mix of upserts,
    // archivals, deletions, and trims, orderedIDs, visibleIDs, and
    // visibleItems must stay aligned. (F9 step 2 collapses these into one
    // ordered list, which simplifies this test to a tautology; until then it
    // pins the parallel indexes against drift.)
    func testStoreIndexes_afterMixedApplyTrimRemoveSequence_stayAligned() throws {
        let alice = makeConversation(name: "Alice", date: 500, unread: 1)
        let bob = makeConversation(name: "Bob", date: 400, unread: 1)
        let carol = makeConversation(name: "Carol", date: 300, unread: 1)
        let dave = makeConversation(name: "Dave", date: 200, unread: 1)
        let erin = makeConversation(name: "Erin", date: 100, unread: 1)
        try stack.saveViewContext()

        var store = ConversationListStore()
        store.replaceAll(with: [alice, bob, carol, dave, erin]) { _ in true }
        assertStoreIndexesAligned(store)

        // Move one row, archive one, delete one, insert a new one.
        dave.lastMessageDate = Date(timeIntervalSince1970: 600)
        carol.archivedAt = Date(timeIntervalSince1970: 600)
        let frank = makeConversation(name: "Frank", date: 450, unread: 1)
        _ = applyUpdate(&store, updated: [dave, carol, frank], deleted: [erin.objectID])
        assertStoreIndexesAligned(store)
        XCTAssertEqual(
            visibleIDs(of: store),
            [dave.objectID, alice.objectID, frank.objectID, bob.objectID]
        )

        _ = store.trimVisibleItems(to: 3)
        assertStoreIndexesAligned(store)

        // A row leaving the visibility filter and a pin promotion in one pass.
        alice.inboxUnreadCount = 0
        frank.pinned = true
        _ = applyUpdate(&store, updated: [alice, frank]) { $0.inboxUnreadCount > 0 }
        assertStoreIndexesAligned(store)
        XCTAssertEqual(visibleIDs(of: store), [frank.objectID, dave.objectID])

        _ = store.trimVisibleItems(to: 1)
        assertStoreIndexesAligned(store)
        XCTAssertEqual(visibleIDs(of: store), [frank.objectID])

        store.removeAll()
        assertStoreIndexesAligned(store)
        XCTAssertTrue(store.visibleItems.isEmpty)
    }

    // MARK: - Helpers

    private func makeConversation(
        name: String,
        snippet: String = "snippet",
        date: TimeInterval,
        id: UUID = UUID(),
        unread: Int32 = 0
    ) -> Conversation {
        ConversationBuilder()
            .withId(id)
            .withDisplayName(name)
            .withSnippet(snippet)
            .visible()
            .withLastMessageDate(Date(timeIntervalSince1970: date))
            .withUnreadCount(unread)
            .build(in: context)
    }

    private func applyUpdate(
        _ store: inout ConversationListStore,
        updated: [Conversation] = [],
        deleted: Set<NSManagedObjectID> = [],
        matchesVisibility: (Conversation) -> Bool = { _ in true }
    ) -> Set<NSManagedObjectID> {
        store.applyChanges(
            updatedConversations: updated,
            deletedIDs: deleted,
            isSourceConversation: { $0.archivedAt == nil },
            matchesVisibility: matchesVisibility
        )
    }

    private func visibleIDs(of store: ConversationListStore) -> [NSManagedObjectID] {
        store.visibleItems.map(\.id)
    }

    /// The parallel-index invariant F9 step 2 will collapse: the ordered ID
    /// list, the visible ID list, and the visible item list must agree, and
    /// itemsByID must hold exactly the ordered rows.
    private func assertStoreIndexesAligned(
        _ store: ConversationListStore,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(store.orderedIDs, store.visibleIDs, file: file, line: line)
        XCTAssertEqual(store.visibleIDs, store.visibleItems.map(\.id), file: file, line: line)
        XCTAssertEqual(Set(store.orderedIDs), Set(store.itemsByID.keys), file: file, line: line)
    }
}
