import XCTest
import CoreData
@testable import esc_chatmail

@MainActor
final class ConversationNameRefreshMigrationTests: XCTestCase {
    private static let legacyConversationNameRefreshMigrationKey = "hasRefreshedConversationNamesV4"
    private static let legacyConversationPreviewRepairMigrationKey = "hasRepairedMissingConversationPreviewsV1"

    private var stack: TestCoreDataStack!
    private var context: NSManagedObjectContext!
    private var migrationFlags: InMemoryMigrationFlagStore!

    override func setUp() {
        super.setUp()
        stack = TestCoreDataStack()
        context = stack.viewContext
        migrationFlags = InMemoryMigrationFlagStore()
    }

    override func tearDown() {
        migrationFlags = nil
        context = nil
        stack = nil
        super.tearDown()
    }

    func testOnAppear_refreshesNamesWithoutRecomputingRollupsOrReorderingConversations() async throws {
        // This test verifies merge-driven behavior: the view model's row
        // snapshots refresh when the background migration's save merges into
        // the view context, so it needs an automerge-enabled stack.
        stack = TestCoreDataStack(automaticallyMergesChanges: true)
        context = stack.viewContext

        let aliceDate = Date(timeIntervalSince1970: 100)
        let bobDate = Date(timeIntervalSince1970: 200)

        let alice = ConversationBuilder()
            .withDisplayName("alice")
            .withSnippet("Old Alice preview")
            .withLastMessageDate(aliceDate)
            .withUnreadCount(7)
            .visible()
            .build(in: context)
        let bob = ConversationBuilder()
            .withDisplayName("bob")
            .withSnippet("Bob preview")
            .withLastMessageDate(bobDate)
            .visible()
            .build(in: context)

        addConversationParticipant(email: "alice@example.com", to: alice)
        addConversationParticipant(email: "bob@example.com", to: bob)

        _ = MessageBuilder()
            .withSnippet("Newest Alice message")
            .withDate(Date(timeIntervalSince1970: 300))
            .inConversation(alice)
            .build(in: context)

        try context.save()

        let viewModel = makeViewModel()
        viewModel.onAppear(conversations: [bob, alice], in: context)

        XCTAssertEqual(filteredConversationIDs(in: viewModel), [bob.objectID, alice.objectID])

        await waitUntil {
            self.migrationFlags.bool(
                forKey: ConversationListViewModel.conversationNameRefreshMigrationKey
            )
        }
        await waitUntil {
            self.displayNameHints(in: viewModel) == ["bob@example.com", "alice@example.com"]
        }

        let refreshedAlice = try fetchConversation(alice.objectID)
        let refreshedBob = try fetchConversation(bob.objectID)

        XCTAssertEqual(filteredConversationIDs(in: viewModel), [bob.objectID, alice.objectID])
        XCTAssertEqual(viewModel.filteredConversationItems.map(\.snapshot.snippet), ["Bob preview", "Old Alice preview"])
        XCTAssertEqual(displayNameHints(in: viewModel), ["bob@example.com", "alice@example.com"])

        XCTAssertEqual(refreshedAlice.displayName, "alice@example.com")
        XCTAssertEqual(refreshedAlice.lastMessageDate, aliceDate)
        XCTAssertEqual(refreshedAlice.snippet, "Old Alice preview")
        XCTAssertEqual(refreshedAlice.inboxUnreadCount, 7)
        XCTAssertNil(refreshedAlice.archivedAt)

        XCTAssertEqual(refreshedBob.displayName, "bob@example.com")
        XCTAssertEqual(refreshedBob.lastMessageDate, bobDate)
        XCTAssertEqual(refreshedBob.snippet, "Bob preview")
        XCTAssertNil(refreshedBob.archivedAt)
    }

    func testRefreshConversationNames_runsWhenLegacyV4MigrationCompleted() async throws {
        migrationFlags.set(
            true,
            forKey: Self.legacyConversationNameRefreshMigrationKey
        )
        let conversation = ConversationBuilder()
            .withDisplayName("Unknown Contact")
            .visible()
            .build(in: context)
        addConversationParticipant(email: "alice@example.com", to: conversation)
        try context.save()

        let viewModel = makeViewModel()
        viewModel.refreshConversationNames()

        await waitUntil {
            self.migrationFlags.bool(
                forKey: ConversationListViewModel.conversationNameRefreshMigrationKey
            )
        }
        await waitUntil {
            (try? self.fetchConversation(conversation.objectID).displayName) == "alice@example.com"
        }

        let refreshed = try fetchConversation(conversation.objectID)
        XCTAssertEqual(refreshed.displayName, "alice@example.com")
    }

    func testRefreshConversationNames_marksMigrationCompleteWhenStoreIsEmpty() {
        let viewModel = makeViewModel()

        viewModel.refreshConversationNames()

        XCTAssertTrue(
            migrationFlags.bool(
                forKey: ConversationListViewModel.conversationNameRefreshMigrationKey
            )
        )
    }

    func testRepairMissingConversationPreviewsContinuesBatchesUntilDrained() async throws {
        var createdConversations: [(conversation: Conversation, expectedSnippet: String)] = []

        for index in 0..<201 {
            let date = Date(timeIntervalSince1970: TimeInterval(1_700_000_000 + index))
            let conversation = ConversationBuilder()
                .withLastMessageDate(date)
                .visible()
                .build(in: context)
            MessageBuilder()
                .withId("preview-repair-batch-\(index)")
                .withDate(date)
                .withSnippet("Repair preview \(index)")
                .inConversation(conversation)
                .build(in: context)

            createdConversations.append((conversation, "Repair preview \(index)"))
        }

        try context.save()
        let expectedSnippets = createdConversations.map { ($0.conversation.objectID, $0.expectedSnippet) }
        let viewModel = makeViewModel()

        viewModel.repairMissingConversationPreviews()

        // Wait on this store's data first: it proves all repair batches landed
        // before observing the test-local completion flag.
        await waitUntil(timeout: 15.0, pollIntervalNanoseconds: 50_000_000) {
            try expectedSnippets.allSatisfy { objectID, expectedSnippet in
                try self.fetchConversation(objectID).snippet == expectedSnippet
            }
        }

        for (objectID, expectedSnippet) in expectedSnippets {
            let repaired = try fetchConversation(objectID)
            XCTAssertEqual(repaired.snippet, expectedSnippet)
        }

        // Draining is what flips the flag; ours is the only repair started
        // with this store, and foreign writers only ever set it to true.
        await waitUntil(timeout: 5.0) {
            self.migrationFlags.bool(
                forKey: ConversationListViewModel.conversationPreviewRepairMigrationKey
            )
        }
    }

    func testRepairMissingConversationPreviewsRunsV2WhenLegacyV1Completed() async throws {
        migrationFlags.set(
            true,
            forKey: Self.legacyConversationPreviewRepairMigrationKey
        )

        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let conversation = ConversationBuilder()
            .withLastMessageDate(date)
            .visible()
            .build(in: context)
        let message = MessageBuilder()
            .withId("preview-repair-v2-chat-preview")
            .withDate(date)
            .withSubject("Subject fallback")
            .withSnippet(" \n\t ")
            .inConversation(conversation)
            .build(in: context)
        message.cleanedSnippet = nil
        message.chatPreviewText = "Recovered chat preview.\n\nSecond line."

        try context.save()

        let viewModel = makeViewModel()
        viewModel.repairMissingConversationPreviews()

        await waitUntil {
            try self.fetchConversation(conversation.objectID).snippet == "Recovered chat preview. Second line."
        }
        await waitUntil {
            self.migrationFlags.bool(
                forKey: ConversationListViewModel.conversationPreviewRepairMigrationKey
            )
        }

        XCTAssertTrue(
            migrationFlags.bool(forKey: Self.legacyConversationPreviewRepairMigrationKey)
        )
    }

    func testUpdateAllConversationDisplayNames_onlyTouchesDisplayNameFields() async throws {
        let lastMessageDate = Date(timeIntervalSince1970: 123)
        let latestInboxDate = Date(timeIntervalSince1970: 120)

        let conversation = ConversationBuilder()
            .withDisplayName("alice")
            .withSnippet("Stable preview")
            .withLastMessageDate(lastMessageDate)
            .withUnreadCount(3)
            .visible()
            .build(in: context)
        conversation.latestInboxDate = latestInboxDate
        conversation.pinned = true
        addConversationParticipant(email: "alice@example.com", to: conversation)
        try context.save()

        let manager = makeConversationManager()
        let backgroundContext = stack.newBackgroundContext()

        await manager.updateAllConversationDisplayNames(in: backgroundContext)
        XCTAssertTrue(stack.saveIfNeeded(context: backgroundContext))

        await waitUntil {
            (try? self.fetchConversation(conversation.objectID).displayName) == "alice@example.com"
        }

        let refreshed = try fetchConversation(conversation.objectID)
        XCTAssertEqual(refreshed.displayName, "alice@example.com")
        XCTAssertEqual(refreshed.snippet, "Stable preview")
        XCTAssertEqual(refreshed.lastMessageDate, lastMessageDate)
        XCTAssertEqual(refreshed.inboxUnreadCount, 3)
        XCTAssertEqual(refreshed.latestInboxDate, latestInboxDate)
        XCTAssertTrue(refreshed.pinned)
        XCTAssertNil(refreshed.archivedAt)
    }

    func testUpdateDisplayNameOnly_doesNotOverwriteNewerSyncMetadataFromStaleBackgroundContext() async throws {
        let initialDate = Date(timeIntervalSince1970: 100)
        let syncedDate = Date(timeIntervalSince1970: 500)
        let archivedDate = Date(timeIntervalSince1970: 480)

        let conversation = ConversationBuilder()
            .withDisplayName("friend")
            .withSnippet("Old preview")
            .withLastMessageDate(initialDate)
            .withUnreadCount(1)
            .visible()
            .build(in: context)
        addConversationParticipant(email: "friend@example.com", to: conversation)
        try context.save()

        let updater = ConversationRollupUpdater()
        let backgroundContext = stack.newBackgroundContext()
        let conversationObjectID = conversation.objectID
        backgroundContext.performAndWait {
            XCTAssertNotNil(try? backgroundContext.existingObject(with: conversationObjectID) as? Conversation)
        }

        conversation.snippet = "Newest synced preview"
        conversation.lastMessageDate = syncedDate
        conversation.inboxUnreadCount = 9
        conversation.latestInboxDate = syncedDate
        conversation.archivedAt = archivedDate
        try context.save()

        backgroundContext.performAndWait {
            guard let staleConversation = try? backgroundContext.existingObject(with: conversationObjectID) as? Conversation else {
                XCTFail("Expected stale conversation in background context")
                return
            }
            updater.updateDisplayNameOnly(for: staleConversation, myEmail: "me@example.com")
        }
        XCTAssertTrue(stack.saveIfNeeded(context: backgroundContext))

        await waitUntil {
            (try? self.fetchConversation(conversationObjectID).displayName) == "friend@example.com"
        }

        let refreshed = try fetchConversation(conversationObjectID)
        XCTAssertEqual(refreshed.displayName, "friend@example.com")
        XCTAssertEqual(refreshed.snippet, "Newest synced preview")
        XCTAssertEqual(refreshed.lastMessageDate, syncedDate)
        XCTAssertEqual(refreshed.inboxUnreadCount, 9)
        XCTAssertEqual(refreshed.latestInboxDate, syncedDate)
        XCTAssertEqual(refreshed.archivedAt, archivedDate)
    }

    private func makeViewModel(currentUserEmail: String = "me@example.com") -> ConversationListViewModel {
        let stack = self.stack!
        let searchService = ConversationSearchService(debounceInterval: 10_000_000)
        let selectionService = ConversationSelectionService(
            messageActions: Dependencies.shared.makeMessageActions(),
            coreDataStack: Dependencies.shared.coreDataStack
        )
        let filterService = ConversationFilterService(
            contactsService: ContactsService(),
            contactEmailLoader: { _ in [] }
        )

        let dependencies = ConversationListDependencies(
            storage: StorageDependencies(
                viewContext: context,
                makeBackgroundContext: { stack.newBackgroundContext() },
                saveIfNeeded: { stack.saveIfNeeded(context: $0) },
                migrationFlags: migrationFlags,
                personCache: Dependencies.shared.personCache,
                profilePhotoResolver: Dependencies.shared.profilePhotoResolver
            ),
            messaging: Dependencies.shared.makeMessagingDependencies(),
            syncEngine: Dependencies.shared.syncEngine,
            foregroundSyncCoordinator: Dependencies.shared.foregroundSyncCoordinator,
            conversationManager: makeConversationManager(currentUserEmail: currentUserEmail),
            makeConversationSearchService: { searchService },
            makeConversationSelectionService: { selectionService },
            makeConversationFilterService: { filterService }
        )

        return ConversationListViewModel(
            dependencies: dependencies,
            searchService: searchService,
            selectionService: selectionService,
            filterService: filterService
        )
    }

    private func makeConversationManager(
        currentUserEmail: String = "me@example.com"
    ) -> ConversationManager {
        ConversationManager(currentUserEmail: { currentUserEmail })
    }

    private func addConversationParticipant(
        email: String,
        displayName: String? = nil,
        to conversation: Conversation
    ) {
        let person = PersonBuilder()
            .withEmail(email)
            .withDisplayName(displayName)
            .build(in: context)
        let participant = context.insertTestObject(ConversationParticipant.self)
        participant.id = UUID()
        participant.role = ParticipantRole.normal.rawValue
        participant.person = person
        participant.conversation = conversation
    }

    private func filteredConversationIDs(
        in viewModel: ConversationListViewModel
    ) -> [NSManagedObjectID] {
        viewModel.filteredConversationItems.map(\.id)
    }

    private func displayNameHints(
        in viewModel: ConversationListViewModel
    ) -> [String?] {
        viewModel.filteredConversationItems.map(\.snapshot.displayNameHint)
    }

    private func fetchConversation(
        _ objectID: NSManagedObjectID
    ) throws -> Conversation {
        // The (default) test context does not auto-merge sibling saves;
        // refresh so reads reflect background-context changes persisted to
        // the store. The automerge-enabled test only calls this after its
        // polls confirm the merge has landed, so the context queue is idle.
        let conversation = try XCTUnwrap(context.existingObject(with: objectID) as? Conversation)
        context.refresh(conversation, mergeChanges: false)
        return conversation
    }

    private func waitUntil(
        timeout: TimeInterval = 2.0,
        pollIntervalNanoseconds: UInt64 = 20_000_000,
        condition: @escaping @MainActor () throws -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let deadline = Date().addingTimeInterval(timeout)

        while Date() < deadline {
            if (try? condition()) == true {
                return
            }
            try? await Task.sleep(nanoseconds: pollIntervalNanoseconds)
        }

        XCTFail("Timed out waiting for condition", file: file, line: line)
    }
}
