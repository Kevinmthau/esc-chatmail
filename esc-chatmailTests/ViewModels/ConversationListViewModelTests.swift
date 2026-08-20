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

    func testOnAppear_recomputesWhenDebouncedSearchUpdates() async throws {
        // createdAt: see makeConversation — shields message-less fixtures
        // from the launch repair's stranded-shell sweep.
        let alice = ConversationBuilder()
            .withDisplayName("Alice")
            .withSnippet("hello")
            .visible()
            .withLastMessageDate(Date(timeIntervalSince1970: 300))
            .withCreatedAt(Date())
            .build(in: context)
        let bob = ConversationBuilder()
            .withDisplayName("Bob")
            .withSnippet("project update")
            .visible()
            .withLastMessageDate(Date(timeIntervalSince1970: 200))
            .withCreatedAt(Date())
            .build(in: context)
        try context.save()

        let viewModel = makeViewModel(
            searchService: ConversationSearchService(debounceInterval: 10_000_000)
        )

        viewModel.onAppear(in: context)
        XCTAssertEqual(filteredConversationIDs(in: viewModel), [alice.objectID, bob.objectID])

        viewModel.searchText = "bob"
        XCTAssertEqual(filteredConversationIDs(in: viewModel), [alice.objectID, bob.objectID])

        await waitForFilteredConversationIDs([bob.objectID], in: viewModel)

        viewModel.searchText = ""
        await waitForFilteredConversationIDs([alice.objectID, bob.objectID], in: viewModel)
    }

    func testApplyConversationChanges_updatesSnippetAndUnreadWithoutDisturbingUnrelatedItems() throws {
        let alice = makeConversation(name: "Alice", snippet: "alpha", date: 300)
        let bob = makeConversation(name: "Bob", snippet: "beta", date: 200)
        let carol = makeConversation(name: "Carol", snippet: "gamma", date: 100)
        try context.save()

        let viewModel = makeViewModel()
        viewModel.onAppear(in: context)
        let initialItems = viewModel.filteredConversationItems

        bob.snippet = "updated beta"
        bob.inboxUnreadCount = 3
        viewModel.applyConversationChanges(updatedConversations: [bob])

        XCTAssertEqual(filteredConversationIDs(in: viewModel), [alice.objectID, bob.objectID, carol.objectID])
        XCTAssertEqual(viewModel.filteredConversationItems[1].snapshot.snippet, "updated beta")
        XCTAssertEqual(viewModel.filteredConversationItems[1].snapshot.inboxUnreadCount, 3)
        XCTAssertEqual(viewModel.filteredConversationItems[0], initialItems[0])
        XCTAssertEqual(viewModel.filteredConversationItems[2], initialItems[2])
        XCTAssertNotEqual(viewModel.filteredConversationItems[1], initialItems[1])
    }

    func testApplyConversationChanges_movesConversationToTopAfterNewMessage() throws {
        let alice = makeConversation(name: "Alice", snippet: "alpha", date: 300)
        let bob = makeConversation(name: "Bob", snippet: "beta", date: 200)
        let carol = makeConversation(name: "Carol", snippet: "gamma", date: 100)
        try context.save()

        let viewModel = makeViewModel()
        viewModel.onAppear(in: context)

        bob.lastMessageDate = Date(timeIntervalSince1970: 400)
        bob.snippet = "newest message"
        viewModel.applyConversationChanges(updatedConversations: [bob])

        XCTAssertEqual(filteredConversationIDs(in: viewModel), [bob.objectID, alice.objectID, carol.objectID])
    }

    func testApplyConversationChanges_reordersForPinAndUnpin() throws {
        let alice = makeConversation(name: "Alice", snippet: "alpha", date: 300)
        let bob = makeConversation(name: "Bob", snippet: "beta", date: 200)
        try context.save()

        let viewModel = makeViewModel()
        viewModel.onAppear(in: context)

        bob.pinned = true
        viewModel.applyConversationChanges(updatedConversations: [bob])
        XCTAssertEqual(filteredConversationIDs(in: viewModel), [bob.objectID, alice.objectID])

        bob.pinned = false
        viewModel.applyConversationChanges(updatedConversations: [bob])
        XCTAssertEqual(filteredConversationIDs(in: viewModel), [alice.objectID, bob.objectID])
    }

    func testApplyConversationChanges_handlesArchiveAndUnarchive() throws {
        let alice = makeConversation(name: "Alice", snippet: "alpha", date: 300)
        let bob = makeConversation(name: "Bob", snippet: "beta", date: 200)
        try context.save()

        let viewModel = makeViewModel()
        viewModel.onAppear(in: context)
        viewModel.toggleSelection(for: bob.objectID)

        bob.archivedAt = Date(timeIntervalSince1970: 500)
        viewModel.applyConversationChanges(updatedConversations: [bob])
        XCTAssertEqual(filteredConversationIDs(in: viewModel), [alice.objectID])
        // An archived row leaves the selection with the window.
        XCTAssertTrue(viewModel.selectedConversationIDs.isEmpty)

        bob.archivedAt = nil
        bob.lastMessageDate = Date(timeIntervalSince1970: 400)
        viewModel.applyConversationChanges(updatedConversations: [bob])
        XCTAssertEqual(filteredConversationIDs(in: viewModel), [bob.objectID, alice.objectID])
    }

    func testApplyConversationChanges_handlesDeleteWithoutDisturbingUnrelatedRows() throws {
        let alice = makeConversation(name: "Alice", snippet: "alpha", date: 300)
        let bob = makeConversation(name: "Bob", snippet: "beta", date: 200)
        let carol = makeConversation(name: "Carol", snippet: "gamma", date: 100)
        try context.save()

        let viewModel = makeViewModel()
        viewModel.onAppear(in: context)
        let initialItems = viewModel.filteredConversationItems
        viewModel.toggleSelection(for: bob.objectID)

        viewModel.applyConversationChanges(deletedIDs: [bob.objectID])

        XCTAssertEqual(filteredConversationIDs(in: viewModel), [alice.objectID, carol.objectID])
        XCTAssertEqual(viewModel.filteredConversationItems[0], initialItems[0])
        XCTAssertEqual(viewModel.filteredConversationItems[1], initialItems[2])
        // A deleted row leaves the selection with the window.
        XCTAssertTrue(viewModel.selectedConversationIDs.isEmpty)
    }

    func testOnAppearFetchesBoundedInitialWindowFromStoreAndExpandsNearEnd() throws {
        let carol = makeConversation(name: "Carol", snippet: "gamma", date: 100)
        let alice = makeConversation(name: "Alice", snippet: "alpha", date: 300)
        let bob = makeConversation(name: "Bob", snippet: "beta", date: 200)
        try context.save()

        let viewModel = makeViewModel(
            windowProvider: ConversationWindowProvider(
                configuration: ConversationListWindowConfiguration(
                    initialLimit: 2,
                    pageSize: 1,
                    preloadThreshold: 1,
                    contactFilterCandidateMultiplier: 5
                )
            )
        )

        viewModel.onAppear(in: context)
        XCTAssertEqual(filteredConversationIDs(in: viewModel), [alice.objectID, bob.objectID])

        let lastVisibleItem = try XCTUnwrap(viewModel.filteredConversationItems.last)
        viewModel.loadMoreIfNeeded(currentItem: lastVisibleItem)

        XCTAssertEqual(filteredConversationIDs(in: viewModel), [alice.objectID, bob.objectID, carol.objectID])

        viewModel.onAppear(in: context)
        XCTAssertEqual(filteredConversationIDs(in: viewModel), [alice.objectID, bob.objectID, carol.objectID])
    }

    func testEqualTimestampWindowUsesStableIDAcrossExpansionLiveInsertAndReappearance() throws {
        let earliestID = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000000"))
        let firstSavedID = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000004"))
        let secondSavedID = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000008"))
        let lastSavedID = try XCTUnwrap(UUID(uuidString: "FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF"))
        let sharedDate = Date(timeIntervalSince1970: 300)

        // createdAt: see makeConversation — shields message-less fixtures
        // from the launch repair's stranded-shell sweep.
        let lastSaved = ConversationBuilder()
            .withId(lastSavedID)
            .withDisplayName("Last")
            .withLastMessageDate(sharedDate)
            .withCreatedAt(Date())
            .visible()
            .build(in: context)
        let firstSaved = ConversationBuilder()
            .withId(firstSavedID)
            .withDisplayName("First")
            .withLastMessageDate(sharedDate)
            .withCreatedAt(Date())
            .visible()
            .build(in: context)
        let secondSaved = ConversationBuilder()
            .withId(secondSavedID)
            .withDisplayName("Second")
            .withLastMessageDate(sharedDate)
            .withCreatedAt(Date())
            .visible()
            .build(in: context)
        try context.save()

        let viewModel = makeViewModel(
            windowProvider: ConversationWindowProvider(
                configuration: ConversationListWindowConfiguration(
                    initialLimit: 2,
                    pageSize: 1,
                    preloadThreshold: 1,
                    contactFilterCandidateMultiplier: 5
                )
            )
        )

        viewModel.onAppear(in: context)
        XCTAssertEqual(
            filteredConversationIDs(in: viewModel),
            [firstSaved.objectID, secondSaved.objectID]
        )

        let lastVisibleItem = try XCTUnwrap(viewModel.filteredConversationItems.last)
        viewModel.loadMoreIfNeeded(currentItem: lastVisibleItem)
        XCTAssertEqual(
            filteredConversationIDs(in: viewModel),
            [firstSaved.objectID, secondSaved.objectID, lastSaved.objectID]
        )

        viewModel.onAppear(in: context)
        XCTAssertEqual(
            filteredConversationIDs(in: viewModel),
            [firstSaved.objectID, secondSaved.objectID, lastSaved.objectID]
        )

        let pendingFirst = ConversationBuilder()
            .withId(earliestID)
            .withDisplayName("Pending first")
            .withLastMessageDate(sharedDate)
            .visible()
            .build(in: context)
        viewModel.applyConversationChanges(updatedConversations: [pendingFirst])
        XCTAssertEqual(
            filteredConversationIDs(in: viewModel),
            [pendingFirst.objectID, firstSaved.objectID, secondSaved.objectID]
        )

        viewModel.onAppear(in: context)
        XCTAssertEqual(
            filteredConversationIDs(in: viewModel),
            [pendingFirst.objectID, firstSaved.objectID, secondSaved.objectID]
        )
    }

    func testSearchFetchesMatchingConversationOutsideCurrentWindow() async throws {
        let alice = makeConversation(name: "Alice", snippet: "alpha", date: 300)
        let bob = makeConversation(name: "Bob", snippet: "beta", date: 200)
        let carol = makeConversation(name: "Carol", snippet: "needle", date: 100)
        try context.save()

        let viewModel = makeViewModel(
            searchService: ConversationSearchService(debounceInterval: 10_000_000),
            windowProvider: ConversationWindowProvider(
                configuration: ConversationListWindowConfiguration(
                    initialLimit: 2,
                    pageSize: 1,
                    preloadThreshold: 1,
                    contactFilterCandidateMultiplier: 5
                )
            )
        )

        viewModel.onAppear(in: context)
        XCTAssertEqual(filteredConversationIDs(in: viewModel), [alice.objectID, bob.objectID])

        viewModel.searchText = "needle"
        await waitForFilteredConversationIDs([carol.objectID], in: viewModel)
    }

    // Revert-check: ConversationFilter.needsInMemoryCandidateScan(hasSearchText:)
    // returning true under search — with a plain fetchLimit the bounded window
    // would fill with the SQL-only fullwidth candidates (CONTAINS[cd] matches
    // them; the in-memory match rejects them) and the José variants would
    // never be reached.
    func testSearchVariantsSurviveBoundedCandidatePagingReappearanceAndExpansion() async throws {
        stack = TestCoreDataStack(storeKind: .sqlite)
        context = stack.viewContext

        for index in 0..<10 {
            let compatibilityMatch = makeConversation(
                name: "ＪＯＳＥ Compatibility \(index)",
                snippet: "SQL-only candidate",
                date: TimeInterval(1_000 - index)
            )
            compatibilityMatch.inboxUnreadCount = 1
        }

        let newestVariant = makeConversation(name: "José Newest", snippet: "variant", date: 300)
        let olderVariant = makeConversation(name: "José Older", snippet: "variant", date: 200)
        let exactMatch = makeConversation(name: "Jose Exact", snippet: "exact", date: 100)
        newestVariant.inboxUnreadCount = 1
        olderVariant.inboxUnreadCount = 1
        exactMatch.inboxUnreadCount = 1
        try context.save()

        let rawCandidateRequest = Conversation.fetchRequest()
        rawCandidateRequest.predicate = NSPredicate(format: "displayName CONTAINS[cd] %@", "Jose")
        rawCandidateRequest.sortDescriptors = [
            NSSortDescriptor(keyPath: \Conversation.lastMessageDate, ascending: false)
        ]
        rawCandidateRequest.fetchLimit = 2
        let rawCandidates = try context.fetch(rawCandidateRequest)
        XCTAssertEqual(
            rawCandidates.compactMap(\.displayName),
            ["ＪＯＳＥ Compatibility 0", "ＪＯＳＥ Compatibility 1"]
        )

        let viewModel = makeViewModel(
            searchService: ConversationSearchService(debounceInterval: 10_000_000),
            windowProvider: ConversationWindowProvider(
                configuration: ConversationListWindowConfiguration(
                    initialLimit: 2,
                    pageSize: 1,
                    preloadThreshold: 1,
                    contactFilterCandidateMultiplier: 5
                )
            )
        )

        viewModel.onAppear(in: context)
        viewModel.searchText = "Jose"

        await waitForFilteredConversationIDs(
            [newestVariant.objectID, olderVariant.objectID],
            in: viewModel
        )

        viewModel.onDisappear()
        viewModel.onAppear(in: context)
        XCTAssertEqual(
            filteredConversationIDs(in: viewModel),
            [newestVariant.objectID, olderVariant.objectID]
        )

        let lastVisibleItem = try XCTUnwrap(viewModel.filteredConversationItems.last)
        viewModel.loadMoreIfNeeded(currentItem: lastVisibleItem)

        XCTAssertEqual(
            filteredConversationIDs(in: viewModel),
            [newestVariant.objectID, olderVariant.objectID, exactMatch.objectID]
        )

        viewModel.currentFilter = .unread
        XCTAssertEqual(
            filteredConversationIDs(in: viewModel),
            [newestVariant.objectID, olderVariant.objectID]
        )

        let lastUnreadItem = try XCTUnwrap(viewModel.filteredConversationItems.last)
        viewModel.loadMoreIfNeeded(currentItem: lastUnreadItem)
        XCTAssertEqual(
            filteredConversationIDs(in: viewModel),
            [newestVariant.objectID, olderVariant.objectID, exactMatch.objectID]
        )
    }

    // Revert-check: ConversationWindowProvider.fetchFilteredWindow's
    // offset-paging continuation (the fetchOffset advance while a batch comes
    // back full) — the contact match sits in the second candidate batch, so
    // stopping after the first batch leaves it unfound.
    func testContactFilterFetchesPastFirstCandidateBatch() async throws {
        let contactEmail = "contact@example.com"

        for index in 0..<10 {
            let person = PersonBuilder()
                .withEmail("other\(index)@example.com")
                .build(in: context)
            _ = makeConversation(
                name: "Other \(index)",
                snippet: "not a contact",
                date: TimeInterval(300 - index),
                participant: person
            )
        }

        let contactPerson = PersonBuilder()
            .withEmail(contactEmail)
            .build(in: context)
        let contactConversation = makeConversation(
            name: "Contact",
            snippet: "older match",
            date: 100,
            participant: contactPerson
        )
        try context.save()

        let filterService = ConversationFilterService(
            contactEmailLoader: { _ in [EmailNormalizer.normalize(contactEmail)] }
        )
        filterService.loadContactsCache()
        await waitUntil {
            filterService.contactEmailsCache.contains(EmailNormalizer.normalize(contactEmail))
        }

        let viewModel = makeViewModel(
            filterService: filterService,
            windowProvider: ConversationWindowProvider(
                configuration: ConversationListWindowConfiguration(
                    initialLimit: 2,
                    pageSize: 1,
                    preloadThreshold: 1,
                    contactFilterCandidateMultiplier: 5
                )
            )
        )

        viewModel.onAppear(in: context)
        viewModel.currentFilter = .contacts

        XCTAssertEqual(filteredConversationIDs(in: viewModel), [contactConversation.objectID])
    }

    func testUnreadFilterFetchesMatchingConversationOutsideInitialWindow() throws {
        for index in 0..<10 {
            _ = makeConversation(
                name: "Read \(index)",
                snippet: "already read",
                date: TimeInterval(300 - index)
            )
        }

        let unreadConversation = makeConversation(name: "Unread", snippet: "needs attention", date: 100)
        unreadConversation.inboxUnreadCount = 2
        try context.save()

        let viewModel = makeViewModel(
            windowProvider: ConversationWindowProvider(
                configuration: ConversationListWindowConfiguration(
                    initialLimit: 2,
                    pageSize: 1,
                    preloadThreshold: 1,
                    contactFilterCandidateMultiplier: 5
                )
            )
        )

        viewModel.onAppear(in: context)
        XCTAssertFalse(filteredConversationIDs(in: viewModel).contains(unreadConversation.objectID))

        viewModel.currentFilter = .unread

        XCTAssertEqual(filteredConversationIDs(in: viewModel), [unreadConversation.objectID])
    }

    func testApplyConversationChangesBackfillsAfterVisibleWindowIsArchived() throws {
        let alice = makeConversation(name: "Alice", snippet: "alpha", date: 300)
        let bob = makeConversation(name: "Bob", snippet: "beta", date: 200)
        let carol = makeConversation(name: "Carol", snippet: "gamma", date: 100)
        try context.save()

        let viewModel = makeViewModel(
            windowProvider: ConversationWindowProvider(
                configuration: ConversationListWindowConfiguration(
                    initialLimit: 2,
                    pageSize: 1,
                    preloadThreshold: 1,
                    contactFilterCandidateMultiplier: 5
                )
            )
        )

        viewModel.onAppear(in: context)
        XCTAssertEqual(filteredConversationIDs(in: viewModel), [alice.objectID, bob.objectID])

        alice.archivedAt = Date(timeIntervalSince1970: 400)
        bob.archivedAt = Date(timeIntervalSince1970: 400)
        viewModel.applyConversationChanges(updatedConversations: [alice, bob])

        XCTAssertEqual(filteredConversationIDs(in: viewModel), [carol.objectID])
    }

    // Revert-check: applyConversationChanges must clear hasLoadedAllConversationWindow
    // after trimVisibleItems. Without that reset the short initial window latches
    // "all loaded" and loadMoreIfNeeded bails at its first guard, leaving the list
    // stuck at 2 rows even though the store now holds 3. The selection assertion
    // additionally pins that a trimmed row leaves the selection
    // (publishVisibleItems → ConversationSelectionService.retainSelection(within:)).
    func testApplyConversationChanges_trimAfterShortInitialWindow_reopensPaging() throws {
        // Initial limit 2; one saved row makes the initial window short.
        let carol = makeConversation(name: "Carol", snippet: "gamma", date: 100)
        try context.save()

        let viewModel = makeViewModel(
            windowProvider: ConversationWindowProvider(
                configuration: ConversationListWindowConfiguration(
                    initialLimit: 2,
                    pageSize: 1,
                    preloadThreshold: 1,
                    contactFilterCandidateMultiplier: 5
                )
            )
        )

        viewModel.onAppear(in: context)
        XCTAssertEqual(filteredConversationIDs(in: viewModel), [carol.objectID])
        viewModel.toggleSelection(for: carol.objectID)

        // Two newer live inserts on the observed context (pending, not saved, so
        // their objectIDs stay stable for the assertions below): objectsDidChange
        // drives applyConversationChanges, which upserts both and trims the
        // window back to the limit, dropping Carol off the tail.
        let alice = makeConversation(name: "Alice", snippet: "alpha", date: 300)
        let bob = makeConversation(name: "Bob", snippet: "beta", date: 200)
        context.processPendingChanges()
        XCTAssertEqual(filteredConversationIDs(in: viewModel), [alice.objectID, bob.objectID])
        // The trimmed row leaves the selection with the window.
        XCTAssertTrue(viewModel.selectedConversationIDs.isEmpty)

        // Pre-fix this stopped at [alice, bob]: the flag still claimed the whole
        // window was loaded, so the trimmed row was unreachable until a re-appear.
        let lastVisibleItem = try XCTUnwrap(viewModel.filteredConversationItems.last)
        viewModel.loadMoreIfNeeded(currentItem: lastVisibleItem)
        XCTAssertEqual(
            filteredConversationIDs(in: viewModel),
            [alice.objectID, bob.objectID, carol.objectID]
        )
    }

    // Revert-check: publishVisibleItems must call
    // ConversationSelectionService.retainSelection(within:). A row that stops
    // matching the filter leaves the store through upsertConversation, which
    // reports nothing to applyConversationChanges — only the publish-time
    // reconciliation drops it from the selection.
    func testApplyConversationChanges_selectedRowLeavesUnreadFilter_dropsItFromSelection() throws {
        let alice = makeConversation(name: "Alice", snippet: "alpha", date: 300)
        let bob = makeConversation(name: "Bob", snippet: "beta", date: 200)
        alice.inboxUnreadCount = 1
        bob.inboxUnreadCount = 1
        try context.save()

        let viewModel = makeViewModel()
        viewModel.onAppear(in: context)
        viewModel.currentFilter = .unread
        XCTAssertEqual(filteredConversationIDs(in: viewModel), [alice.objectID, bob.objectID])

        viewModel.toggleSelection(for: alice.objectID)
        viewModel.toggleSelection(for: bob.objectID)
        XCTAssertEqual(viewModel.selectedConversationIDs, [alice.objectID, bob.objectID])

        // A remote mark-read lands on the observed context: objectsDidChange
        // drives applyConversationChanges, whose upsert hides Bob from the
        // unread window. Pre-fix Bob stayed selected ("2 Selected" with one
        // checkmark) and the batch archive/spam actions acted on the hidden row.
        bob.inboxUnreadCount = 0
        context.processPendingChanges()

        XCTAssertEqual(filteredConversationIDs(in: viewModel), [alice.objectID])
        XCTAssertEqual(viewModel.selectedConversationIDs, [alice.objectID])
        XCTAssertEqual(viewModel.selectedConversationIDs.count, 1)
    }

    // Revert-check: conversationsAffectedByPersonChanges in
    // ConversationListViewModel+ChangeObservation — a Person rename surfaces
    // as a Person update with no Conversation in the payload, so only that
    // fan-out re-snapshots the affected row; without it the fingerprint never
    // refreshes and this wait times out.
    func testPersonDisplayNameChangeRefreshesAffectedConversationItem() async throws {
        let person = PersonBuilder()
            .withEmail("info@bonbonwhims.com")
            .withDisplayName("Info")
            .build(in: context)
        let conversation = makeConversation(name: "Info", snippet: "alpha", date: 300, participant: person)
        try context.save()

        let viewModel = makeViewModel()
        viewModel.onAppear(in: context)
        let initialItem = try XCTUnwrap(viewModel.filteredConversationItems.first)

        person.displayName = "BONBONWHIMS"
        context.processPendingChanges()

        await waitUntil {
            viewModel.filteredConversationItems.first != initialItem
        }

        let updatedItem = try XCTUnwrap(viewModel.filteredConversationItems.first)
        XCTAssertEqual(updatedItem.id, conversation.objectID)
        XCTAssertNotEqual(
            updatedItem.snapshot.participantDisplayNameFingerprint,
            initialItem.snapshot.participantDisplayNameFingerprint
        )
    }

    // Revert-check: request.includesPendingChanges = true on
    // ConversationWindowProvider.fetchWindow's unfiltered path — this
    // .all/no-search re-appear takes the plain fetchLimit fetch, and only
    // that flag lets the refetch see the unsaved optimistic row instead of
    // replacing the live snapshot with persisted conversations only.
    func testOptimisticUnsavedConversation_survivesReAppear() async throws {
        let alice = makeConversation(name: "Alice", snippet: "alpha", date: 300)
        let bob = makeConversation(name: "Bob", snippet: "beta", date: 200)
        try context.save()

        let viewModel = makeViewModel()
        viewModel.onAppear(in: context)
        XCTAssertEqual(filteredConversationIDs(in: viewModel), [alice.objectID, bob.objectID])

        // Optimistic insert: a brand-new Conversation created in the view context but
        // intentionally NOT saved (matches GmailSendService.createOptimisticMessage which
        // calls processPendingChanges() without save() to keep the main thread responsive).
        let carol = ConversationBuilder()
            .withDisplayName("Carol")
            .withSnippet("newest optimistic")
            .visible()
            .withLastMessageDate(Date(timeIntervalSince1970: 400))
            .hasInboxMessages(false)
            .build(in: context)
        context.processPendingChanges()

        await waitForFilteredConversationIDs(
            [carol.objectID, alice.objectID, bob.objectID],
            in: viewModel
        )

        // Simulate the View re-appearing (e.g. nav pop from ChatView, sheet dismiss).
        // The provider-backed fetch must include the unsaved optimistic row instead of
        // replacing the live snapshot with only persisted conversations.
        viewModel.onAppear(in: context)

        XCTAssertEqual(
            filteredConversationIDs(in: viewModel),
            [carol.objectID, alice.objectID, bob.objectID]
        )
        XCTAssertEqual(viewModel.filteredConversationItems.first?.snapshot.snippet, "newest optimistic")
    }

    // Revert-check: onDisappear's deliberate omission of
    // conversationChangesCancellable — cancelling the objectsDidChange
    // subscription on a transient disappear would drop the post-disappear
    // update and this wait would time out.
    func testOnDisappear_keepsObservingConversationChangesForTransientNavigation() async throws {
        let alice = makeConversation(name: "Alice", snippet: "alpha", date: 300)
        let bob = makeConversation(name: "Bob", snippet: "beta", date: 200)
        try context.save()

        let viewModel = makeViewModel()
        viewModel.onAppear(in: context)
        XCTAssertEqual(filteredConversationIDs(in: viewModel), [alice.objectID, bob.objectID])

        viewModel.onDisappear()

        bob.lastMessageDate = Date(timeIntervalSince1970: 400)
        bob.snippet = "newest message"
        context.processPendingChanges()

        await waitForFilteredConversationIDs([bob.objectID, alice.objectID], in: viewModel)
        XCTAssertEqual(viewModel.filteredConversationItems.first?.snapshot.snippet, "newest message")
    }

    // Revert-check: the `if !preservePreviewRepair` guard keeping
    // searchService.cleanup() out of a transient onDisappear — cleanup
    // cancels the pending debounce task, so the "bob" search would never
    // apply and this wait would time out.
    func testOnDisappear_preservesPendingDebouncedSearchForTransientNavigation() async throws {
        let alice = makeConversation(name: "Alice", snippet: "alpha", date: 300)
        let bob = makeConversation(name: "Bob", snippet: "beta", date: 200)
        try context.save()

        let viewModel = makeViewModel(
            searchService: ConversationSearchService(debounceInterval: 50_000_000)
        )
        viewModel.onAppear(in: context)
        XCTAssertEqual(filteredConversationIDs(in: viewModel), [alice.objectID, bob.objectID])

        viewModel.searchText = "bob"
        viewModel.onDisappear()

        await waitForFilteredConversationIDs([bob.objectID], in: viewModel)
        XCTAssertEqual(viewModel.searchText, "bob")
    }

    private func waitForFilteredConversationIDs(
        _ expectedIDs: [NSManagedObjectID],
        in viewModel: ConversationListViewModel,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        if filteredConversationIDs(in: viewModel) == expectedIDs {
            return
        }

        let expectation = expectation(description: "filtered conversations updated")
        var cancellable: AnyCancellable?
        cancellable = viewModel.$filteredConversationItems
            .sink { items in
                guard items.map(\.id) == expectedIDs else { return }
                expectation.fulfill()
                cancellable?.cancel()
            }

        await fulfillment(of: [expectation], timeout: 1.0)
        XCTAssertEqual(filteredConversationIDs(in: viewModel), expectedIDs, file: file, line: line)
    }

    /// Builds the view model against this suite's stack via
    /// `ConversationListDependencies.forTesting`, so storage, migration
    /// flags, and the contact loader never fall back to `Dependencies.shared`
    /// / `CoreDataStack.shared` / `UserDefaults.standard`.
    private func makeViewModel(
        searchService: ConversationSearchService? = nil,
        filterService: ConversationFilterService? = nil,
        windowProvider: ConversationWindowProvider = ConversationWindowProvider()
    ) -> ConversationListViewModel {
        ConversationListViewModel(
            dependencies: .forTesting(
                stack: stack,
                searchService: searchService,
                filterService: filterService
            ),
            windowProvider: windowProvider
        )
    }

    /// createdAt keeps these message-less fixtures inside the stranded-shell
    /// grace period: with test-owned storage the launch repair scheduled by
    /// onAppear(in:) sweeps THIS suite's store, and without createdAt it
    /// would archive every saved conversation that has a lastMessageDate but
    /// no Message rows mid-test.
    private func makeConversation(
        name: String,
        snippet: String,
        date: TimeInterval,
        participant: Person? = nil
    ) -> Conversation {
        let builder = ConversationBuilder()
            .withDisplayName(name)
            .withSnippet(snippet)
            .visible()
            .withLastMessageDate(Date(timeIntervalSince1970: date))
            .withCreatedAt(Date())
        if let participant {
            _ = builder.withParticipant(participant)
        }
        return builder.build(in: context)
    }

    private func waitUntil(
        timeout: TimeInterval = 1.0,
        pollIntervalNanoseconds: UInt64 = 20_000_000,
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

    private func filteredConversationIDs(in viewModel: ConversationListViewModel) -> [NSManagedObjectID] {
        viewModel.filteredConversationItems.map(\.id)
    }

    // MARK: - objectsDidChange relevance guard

    func testRelevanceGuard_messageOnlyChanges_areIrrelevant() throws {
        let conversation = ConversationBuilder().visible().build(in: context)
        let message = MessageBuilder().inConversation(conversation).build(in: context)
        try context.save()

        let userInfo: [AnyHashable: Any] = [NSUpdatedObjectsKey: Set<NSManagedObject>([message])]
        XCTAssertFalse(ConversationListViewModel.isRelevantConversationListChange(userInfo))
    }

    func testRelevanceGuard_conversationChanges_areRelevantInEverySet() throws {
        let conversation = ConversationBuilder().visible().build(in: context)
        try context.save()

        for key in [NSInsertedObjectsKey, NSUpdatedObjectsKey, NSRefreshedObjectsKey, NSDeletedObjectsKey, NSInvalidatedObjectsKey] {
            let userInfo: [AnyHashable: Any] = [key: Set<NSManagedObject>([conversation])]
            XCTAssertTrue(
                ConversationListViewModel.isRelevantConversationListChange(userInfo),
                "conversation change in \(key) must be relevant"
            )
        }
    }

    func testRelevanceGuard_personChanges_relevantOnlyWhenUpdatedOrRefreshed() throws {
        let person = PersonBuilder().build(in: context)
        try context.save()

        XCTAssertTrue(ConversationListViewModel.isRelevantConversationListChange(
            [NSUpdatedObjectsKey: Set<NSManagedObject>([person])]
        ))
        XCTAssertTrue(ConversationListViewModel.isRelevantConversationListChange(
            [NSRefreshedObjectsKey: Set<NSManagedObject>([person])]
        ))
        XCTAssertFalse(ConversationListViewModel.isRelevantConversationListChange(
            [NSInsertedObjectsKey: Set<NSManagedObject>([person])]
        ))
    }

    func testRelevanceGuard_emptyOrNilUserInfo_isIrrelevant() {
        XCTAssertFalse(ConversationListViewModel.isRelevantConversationListChange(nil))
        XCTAssertFalse(ConversationListViewModel.isRelevantConversationListChange([:]))
    }
}
