import XCTest
import CoreData
import Combine
@testable import esc_chatmail

/// What a merged Person change costs the conversation list: the window-bounded fan-out
/// in `ConversationListViewModel+ChangeObservation` (`conversationsAffectedByPersonChanges`)
/// and the filter in front of it (`ConversationListPersonChangePolicy`). Architecture
/// review 2026-11: conversation-list-ui#4, contacts-person#6, gap-message-shape-extremes#5
/// and the list half of gap-change-propagation-pipeline#1.
///
/// Every test runs on a SQLite store. Whether the list walked a Person's conversations is
/// read from what the observed context registered, which it retains
/// (`retainsRegisteredObjects`) so nothing the list touched is let go before the
/// assertions: a walk registers every conversation and conversation participant the
/// Person has. `hasFault(forRelationshipNamed: "conversationParticipations")` is no
/// witness: it read true after the old walk too (measured by PR 527's review).
///
/// Every fixture, save, and assertion goes through the suite's main-queue context
/// (`TestCoreDataStack.makeMainQueueViewContext()`), as in
/// `ConversationListViewModelTests`.
@MainActor
final class ConversationListViewModelPersonChangeTests: XCTestCase {
    private var stack: TestCoreDataStack!
    private var viewContext: NSManagedObjectContext!

    /// `nonisolated`: the background context's `perform` block reads it, and that block is
    /// `@Sendable`, where a main-actor property is a warning.
    nonisolated private static let patEmail = "pat@example.com"

    override func setUp() {
        super.setUp()
        stack = TestCoreDataStack(storeKind: .sqlite)
        viewContext = stack.makeMainQueueViewContext()
    }

    override func tearDown() {
        viewContext = nil
        stack = nil
        super.tearDown()
    }

    // MARK: - Window-bounded fan-out

    /// A Person in 200 conversations (10 unarchived, 190 archived) is renamed while the
    /// window shows 5 of them: the 5 rows show the new name, and nothing else the Person
    /// joined is read. Before, the list walked the Person's `conversationParticipations`,
    /// faulted every one of the 200 conversations and snapshotted the unarchived ones past
    /// the window before the trim dropped them.
    // Revert-check: `conversationsAffectedByPersonChanges`'s window-bounded fetch (the old
    // `person.conversationParticipations` walk fires the to-many fault and registers all
    // 200 conversations, archived ones included).
    func testPersonRename_refreshesTheWindowRows_andReadsNothingElseThePersonJoined() throws {
        let fixture = try makePersonInManyConversations(unarchived: 10, archived: 190)
        viewContext.retainsRegisteredObjects = true
        let viewModel = makeViewModel(windowLimit: 5)
        viewModel.onAppear(in: viewContext)
        XCTAssertEqual(filteredConversationIDs(in: viewModel), Array(fixture.unarchivedIDs.prefix(5)))

        let person = try XCTUnwrap(viewContext.existingObject(with: fixture.personID) as? Person)

        person.displayName = "Pat Smith"
        viewContext.processPendingChanges()

        for item in viewModel.filteredConversationItems {
            XCTAssertEqual(
                item.snapshot.participantDisplayNames,
                [ConversationSnapshot.ParticipantDisplayName(email: Self.patEmail, displayName: "Pat Smith")],
                "Every window row shows the new name"
            )
        }
        XCTAssertLessThanOrEqual(
            registeredConversationParticipantCount(),
            5,
            "Only the window rows' participants (one each) are read, not all 200 of the Person's"
        )
        let outsideWindow = fixture.archivedIDs + fixture.unarchivedIDs.dropFirst(5)
        XCTAssertEqual(
            outsideWindow.filter { viewContext.registeredObject(for: $0) != nil },
            [],
            "No conversation outside the window is read"
        )
    }

    /// An optimistic send's conversation, as the send makes it: unsaved in the view context
    /// and given a permanent ID before the list first sees it
    /// (`GmailSendService.createOptimisticMessage` obtains permanent IDs before
    /// `processPendingChanges`, and `ChatViewModel` does too). The store knows nothing of
    /// the row, so a fetch by its ID cannot find it, and it is taken from the context.
    // Revert-check: `registered.hasChanges` in `conversationsAffectedByPersonChanges`
    // (without it the row goes to the stored-row fetch, which does not return it, and it
    // keeps the old name while the stored rows show the new one). Found by PR 527's
    // review: the temporary-ID test below alone did not catch that revert.
    func testPersonRename_refreshesAnUnsavedWindowRowWithAPermanentID() throws {
        let (viewModel, optimistic, person) = try makeWindowWithAnUnsavedRow(permanentID: true)
        XCTAssertFalse(optimistic.objectID.isTemporaryID, "Precondition: a permanent ID, as an optimistic send has")
        XCTAssertTrue(optimistic.isInserted, "Precondition: unsaved")

        person.displayName = "Pat Smith"
        viewContext.processPendingChanges()

        assertEveryRowShowsTheNewName(in: viewModel, unsavedRow: optimistic)
    }

    /// The same row before it has been given a permanent ID: a temporary ID, which no
    /// fetch may be asked about.
    // Revert-check: `registered.hasChanges` in `conversationsAffectedByPersonChanges`
    // (without it the row is skipped as an ID the store cannot answer for).
    func testPersonRename_refreshesAnUnsavedWindowRowWithATemporaryID() throws {
        let (viewModel, optimistic, person) = try makeWindowWithAnUnsavedRow(permanentID: false)
        XCTAssertTrue(optimistic.objectID.isTemporaryID, "Precondition: a temporary ID")

        person.displayName = "Pat Smith"
        viewContext.processPendingChanges()

        assertEveryRowShowsTheNewName(in: viewModel, unsavedRow: optimistic)
    }

    /// Two stored rows with Pat, and an unsaved one, newest, entering the window.
    private func makeWindowWithAnUnsavedRow(
        permanentID: Bool
    ) throws -> (ConversationListViewModel, Conversation, Person) {
        let fixture = try makePersonInManyConversations(unarchived: 2, archived: 0)
        let viewModel = makeViewModel(windowLimit: 5)
        viewModel.onAppear(in: viewContext)

        let person = try XCTUnwrap(viewContext.existingObject(with: fixture.personID) as? Person)
        let optimistic = ConversationBuilder()
            .withDisplayName("Pat")
            .withSnippet("sending")
            .visible()
            .withLastMessageDate(Date(timeIntervalSince1970: 5_000))
            .withCreatedAt(Date())
            .withParticipant(person)
            .build(in: viewContext)
        if permanentID {
            try viewContext.obtainPermanentIDs(for: [optimistic])
        }
        viewContext.processPendingChanges()
        XCTAssertEqual(filteredConversationIDs(in: viewModel).first, optimistic.objectID)
        return (viewModel, optimistic, person)
    }

    private func assertEveryRowShowsTheNewName(
        in viewModel: ConversationListViewModel,
        unsavedRow: Conversation,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(viewModel.filteredConversationItems.count, 3, file: file, line: line)
        for item in viewModel.filteredConversationItems {
            XCTAssertEqual(
                item.snapshot.participantDisplayNames.map(\.displayName),
                ["Pat Smith"],
                "\(item.id == unsavedRow.objectID ? "The unsaved row" : "A stored row") shows the new name",
                file: file,
                line: line
            )
        }
    }

    // MARK: - The filter in front of the fetch

    /// A Person change that no row can show asks the store nothing: a window Person's
    /// avatar address (no row's snapshot reads it), and a rename of a Person in no window
    /// row. A rename a window row shows costs one fetch.
    // Revert-check: the `ConversationListPersonChangePolicy.mayChangeWindowRows` filter in
    // `conversationsAffectedByPersonChanges` (without it the avatar change fetches; the
    // rename of Sam fetches nothing either way, because no row shows Sam's address).
    func testPersonChange_thatNoWindowRowShows_fetchesNothing() throws {
        let pat = PersonBuilder().withEmail(Self.patEmail).withDisplayName("Pat").build(in: viewContext)
        let sam = PersonBuilder().withEmail("sam@example.com").withDisplayName("Sam").build(in: viewContext)
        _ = makeConversation(name: "Pat", date: 300, participant: pat)
        _ = makeConversation(name: "Sam", date: 100, participant: sam, archived: true)
        try viewContext.save()

        let observed = EntityFetchFailingContext(
            failingEntityName: "Conversation",
            coordinator: stack.persistentContainer.persistentStoreCoordinator,
            concurrencyType: .mainQueueConcurrencyType
        )
        observed.failsFetches = false
        let viewModel = makeViewModel(windowLimit: 5)
        viewModel.onAppear(in: observed)
        XCTAssertEqual(viewModel.filteredConversationItems.count, 1)
        let fetchesAfterAppear = observed.succeededFetches

        let observedPat = try XCTUnwrap(observed.existingObject(with: pat.objectID) as? Person)
        observedPat.avatarURL = "https://example.com/pat.png"
        observed.processPendingChanges()
        XCTAssertEqual(observed.succeededFetches, fetchesAfterAppear, "An avatar address is not on the row")

        let observedSam = try XCTUnwrap(observed.existingObject(with: sam.objectID) as? Person)
        observedSam.displayName = "Sam Jones"
        observed.processPendingChanges()
        XCTAssertEqual(observed.succeededFetches, fetchesAfterAppear, "Sam is in no window row")

        observedPat.displayName = "Pat Smith"
        observed.processPendingChanges()
        XCTAssertEqual(observed.succeededFetches, fetchesAfterAppear + 1, "One fetch over the window")
        XCTAssertEqual(
            viewModel.filteredConversationItems.first?.snapshot.participantDisplayNames.map(\.displayName),
            ["Pat Smith"]
        )
    }

    /// A sibling context saves a new message naming a window Person in a conversation
    /// outside the window (the inverse-only change every synced message makes to its
    /// sender and recipients). The merge reports the Person as changed; the list reads
    /// none of its conversations for it, and no row changes.
    // Revert-check: `conversationsAffectedByPersonChanges` (the old walk fires the Person's
    // `conversationParticipations` and registers its archived conversations).
    func testMergedSaveNamingAWindowPerson_readsNoneOfThePersonsConversations() async throws {
        let fixture = try makePersonInManyConversations(unarchived: 1, archived: 200)
        viewContext.automaticallyMergesChangesFromParent = true
        viewContext.retainsRegisteredObjects = true
        let viewModel = makeViewModel(windowLimit: 5)
        viewModel.onAppear(in: viewContext)
        XCTAssertEqual(filteredConversationIDs(in: viewModel), fixture.unarchivedIDs)
        let itemsBefore = viewModel.filteredConversationItems

        // The merge reports a Person it refreshed; counted so the test fails, rather than
        // passing for nothing, on a system whose merge reported no inverse-only change.
        var reportsNamingThePerson = 0
        let reports = NotificationCenter.default.publisher(
            for: .NSManagedObjectContextObjectsDidChange,
            object: viewContext
        )
        .sink { notification in
            let changed = [NSUpdatedObjectsKey, NSRefreshedObjectsKey].flatMap { key in
                (notification.userInfo?[key] as? Set<NSManagedObject>) ?? []
            }
            if changed.contains(where: { $0.objectID == fixture.personID }) {
                reportsNamingThePerson += 1
            }
        }
        defer { reports.cancel() }

        let archivedID = try XCTUnwrap(fixture.archivedIDs.first)
        let background = stack.newBackgroundContext()
        try await background.perform {
            let conversation = try XCTUnwrap(background.existingObject(with: archivedID) as? Conversation)
            let person = try XCTUnwrap(background.existingObject(with: fixture.personID) as? Person)
            let message = MessageBuilder()
                .withSender(email: Self.patEmail, name: "Pat")
                .inConversation(conversation)
                .build(in: background)
            let participant = background.insertTestObject(MessageParticipant.self)
            participant.id = UUID()
            participant.participantKind = .from
            participant.message = message
            participant.person = person
            try background.save()
        }

        await waitUntil { reportsNamingThePerson > 0 }
        // The window row's participant alone: the sibling-save path reads the saved
        // conversation's own attributes, and nothing of its participants once its place
        // puts it outside the window (`conversationsToApply`; before that it read them,
        // and the count was 2). The old walk registered all 201 of the Person's.
        XCTAssertLessThanOrEqual(
            registeredConversationParticipantCount(),
            1,
            "Only the window row's participant is read"
        )
        // The conversation the message went to is a changed Conversation of the save, whose
        // own attributes the sibling-save path reads to place it (`conversationsToApply`'s
        // first read, which then leaves it out); the other 199 are the Person's alone.
        XCTAssertEqual(
            fixture.archivedIDs.dropFirst().filter { viewContext.registeredObject(for: $0) != nil },
            [],
            "No archived conversation is read for the Person"
        )
        XCTAssertEqual(viewModel.filteredConversationItems, itemsBefore)
    }

    // MARK: - Helpers

    private struct PersonFixture {
        let personID: NSManagedObjectID
        /// Newest first, the window's order.
        let unarchivedIDs: [NSManagedObjectID]
        let archivedIDs: [NSManagedObjectID]
    }

    /// Pat in `unarchived + archived` conversations, saved, and the context reset, so
    /// nothing is registered and Pat's relationships are faults when the list first reads.
    private func makePersonInManyConversations(unarchived: Int, archived: Int) throws -> PersonFixture {
        let person = PersonBuilder().withEmail(Self.patEmail).withDisplayName("Pat").build(in: viewContext)
        let unarchivedRows = (0..<unarchived).map { index in
            makeConversation(name: "Pat \(index)", date: TimeInterval(1_000 - index), participant: person)
        }
        let archivedRows = (0..<archived).map { index in
            makeConversation(name: "Old \(index)", date: TimeInterval(500 - index), participant: person, archived: true)
        }
        try viewContext.save()
        let fixture = PersonFixture(
            personID: person.objectID,
            unarchivedIDs: unarchivedRows.map(\.objectID),
            archivedIDs: archivedRows.map(\.objectID)
        )
        viewContext.reset()
        return fixture
    }

    /// createdAt keeps these message-less fixtures inside the launch repair's
    /// stranded-shell grace period (see `ConversationListViewModelTests.makeConversation`).
    @discardableResult
    private func makeConversation(
        name: String,
        date: TimeInterval,
        participant: Person,
        archived: Bool = false
    ) -> Conversation {
        let builder = ConversationBuilder()
            .withDisplayName(name)
            .withSnippet("snippet")
            .withLastMessageDate(Date(timeIntervalSince1970: date))
            .withCreatedAt(Date())
            .withParticipant(participant)
        _ = archived ? builder.archived() : builder.visible()
        return builder.build(in: viewContext)
    }

    /// The launch passes are marked done
    /// (`InMemoryMigrationFlagStore.withConversationListLaunchPassesDone`): their saves
    /// would register rows and change snapshots under the tests that await.
    private func makeViewModel(windowLimit: Int) -> ConversationListViewModel {
        let migrationFlags = InMemoryMigrationFlagStore.withConversationListLaunchPassesDone()
        return ConversationListViewModel(
            dependencies: .forTesting(stack: stack, viewContext: viewContext, migrationFlags: migrationFlags),
            windowProvider: ConversationWindowProvider(
                configuration: ConversationListWindowConfiguration(
                    initialLimit: windowLimit,
                    pageSize: windowLimit,
                    preloadThreshold: 1,
                    contactFilterCandidateMultiplier: 5
                )
            )
        )
    }

    /// The conversation participants the observed context has registered, counted by type
    /// alone so the count fires nothing. The window rows' snapshot builds register theirs;
    /// a walk of a Person's `conversationParticipations` registers every one the Person has.
    private func registeredConversationParticipantCount() -> Int {
        viewContext.registeredObjects.filter { $0 is ConversationParticipant }.count
    }

    private func filteredConversationIDs(in viewModel: ConversationListViewModel) -> [NSManagedObjectID] {
        viewModel.filteredConversationItems.map(\.id)
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
