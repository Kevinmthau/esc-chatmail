import XCTest
import CoreData
@testable import esc_chatmail

@MainActor
final class ConversationNameRefreshMigrationTests: XCTestCase {
    private static let legacyConversationNameRefreshMigrationKey = "hasRefreshedConversationNamesV4"

    private var stack: TestCoreDataStack!
    private var context: NSManagedObjectContext!

    override func setUp() {
        super.setUp()
        stack = TestCoreDataStack()
        context = stack.viewContext
        UserDefaults.standard.removeObject(
            forKey: Self.legacyConversationNameRefreshMigrationKey
        )
        UserDefaults.standard.removeObject(
            forKey: ConversationListViewModel.conversationNameRefreshMigrationKey
        )
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(
            forKey: Self.legacyConversationNameRefreshMigrationKey
        )
        UserDefaults.standard.removeObject(
            forKey: ConversationListViewModel.conversationNameRefreshMigrationKey
        )
        context = nil
        stack = nil
        super.tearDown()
    }

    func testOnAppear_refreshesNamesWithoutRecomputingRollupsOrReorderingConversations() async throws {
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
            UserDefaults.standard.bool(
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
        UserDefaults.standard.set(
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
            UserDefaults.standard.bool(
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
            UserDefaults.standard.bool(
                forKey: ConversationListViewModel.conversationNameRefreshMigrationKey
            )
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
        var staleConversation: Conversation!
        backgroundContext.performAndWait {
            staleConversation = try? backgroundContext.existingObject(with: conversation.objectID) as? Conversation
        }
        XCTAssertNotNil(staleConversation)

        conversation.snippet = "Newest synced preview"
        conversation.lastMessageDate = syncedDate
        conversation.inboxUnreadCount = 9
        conversation.latestInboxDate = syncedDate
        conversation.archivedAt = archivedDate
        try context.save()

        backgroundContext.performAndWait {
            updater.updateDisplayNameOnly(for: staleConversation, myEmail: "me@example.com")
        }
        XCTAssertTrue(stack.saveIfNeeded(context: backgroundContext))

        await waitUntil {
            (try? self.fetchConversation(conversation.objectID).displayName) == "friend@example.com"
        }

        let refreshed = try fetchConversation(conversation.objectID)
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
        let participant = ConversationParticipant(context: context)
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
        try XCTUnwrap(context.existingObject(with: objectID) as? Conversation)
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
