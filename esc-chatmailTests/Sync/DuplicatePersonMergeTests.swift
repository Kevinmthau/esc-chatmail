import XCTest
import CoreData
@testable import esc_chatmail

/// Pins the duplicate-Person merge pass. `Person.email` has no uniqueness
/// constraint and the conversation creation serializer's dedicated shell
/// context cannot see a Person still pending in the caller's batch, so
/// duplicate rows for one address are produced routinely; this pass is what
/// keeps them from being permanent.
final class DuplicatePersonMergeTests: XCTestCase {
    private var stack: TestCoreDataStack!
    private var coreDataStack: CoreDataStack!
    private var context: NSManagedObjectContext!

    private static let me = "me@example.com"
    private static let alice = "alice@example.com"

    override func setUp() {
        super.setUp()
        stack = TestCoreDataStack()
        coreDataStack = CoreDataStack(persistentContainerForTesting: stack.persistentContainer)
        context = stack.viewContext
    }

    override func tearDown() {
        context = nil
        coreDataStack = nil
        stack = nil
        super.tearDown()
    }

    private func makeService() -> DataCleanupService {
        DataCleanupService(
            coreDataStack: coreDataStack,
            conversationManager: ConversationManager(currentUserEmail: { Self.me }),
            migrationFlags: InMemoryMigrationFlagStore(),
            identityAliasProvider: { _ in [Self.me] }
        )
    }

    @discardableResult
    private func addParticipant(person: Person, to conversation: Conversation) -> ConversationParticipant {
        let participant = context.insertTestObject(ConversationParticipant.self)
        participant.id = UUID()
        participant.participantRole = .normal
        participant.person = person
        participant.conversation = conversation
        return participant
    }

    @discardableResult
    private func addMessageParticipant(person: Person, to message: Message, kind: String = "from") -> MessageParticipant {
        let participant = context.insertTestObject(MessageParticipant.self)
        participant.id = UUID()
        participant.kind = kind
        participant.person = person
        participant.message = message
        return participant
    }

    private func personRows(forEmail email: String) throws -> [Person] {
        let request = Person.fetchRequest()
        request.predicate = NSPredicate(format: "email == %@", email)
        return try context.fetch(request)
    }

    /// The core contract: two rows for one address collapse to one.
    func testCollapsesDuplicateRowsForOneEmail() async throws {
        PersonBuilder().withEmail(Self.alice).withDisplayName("Alice Smith").build(in: context)
        PersonBuilder().withEmail(Self.alice).noDisplayName().build(in: context)
        try context.save()

        await makeService().mergeDuplicatePersons(in: context)

        let rows = try personRows(forEmail: Self.alice)
        XCTAssertEqual(rows.count, 1, "Duplicate rows for one address must collapse")
        XCTAssertEqual(rows.first?.displayName, "Alice Smith", "The richer identity must survive")
    }

    /// Both Person relationships delete-cascade, so the merge must end with
    /// every participation still present and pointing at the survivor rather
    /// than stranding a participant-less conversation. Note this pins the
    /// outcome, not the repoint-before-delete ordering: Core Data defers
    /// cascades to processPendingChanges, so reversing that order still passes.
    func testRepointsParticipationsInsteadOfCascadingThemAway() async throws {
        let survivor = PersonBuilder().withEmail(Self.alice).withDisplayName("Alice Smith").build(in: context)
        let loser = PersonBuilder().withEmail(Self.alice).noDisplayName().build(in: context)

        let survivorConversation = ConversationBuilder().withParticipantHash("hash-survivor").visible().build(in: context)
        addParticipant(person: survivor, to: survivorConversation)

        let loserConversation = ConversationBuilder().withParticipantHash("hash-loser").visible().build(in: context)
        addParticipant(person: loser, to: loserConversation)
        let loserConversationID = loserConversation.id
        try context.save()

        await makeService().mergeDuplicatePersons(in: context)

        let rows = try personRows(forEmail: Self.alice)
        XCTAssertEqual(rows.count, 1)
        let merged = try XCTUnwrap(rows.first)

        let participantRequest = ConversationParticipant.fetchRequest()
        let participants = try context.fetch(participantRequest)
        XCTAssertEqual(participants.count, 2, "Neither participant row may be cascade-deleted")
        XCTAssertTrue(
            participants.allSatisfy { $0.person === merged },
            "Every participation must point at the survivor"
        )

        let conversationRequest = Conversation.fetchRequest()
        conversationRequest.predicate = NSPredicate(format: "id == %@", loserConversationID as CVarArg)
        let orphaned = try XCTUnwrap(try context.fetch(conversationRequest).first)
        XCTAssertEqual(
            orphaned.participants?.count, 1,
            "The loser's conversation must keep its participant, not be stranded identity-less"
        )
    }

    /// Repointing a participation the survivor already holds would list the
    /// same person twice in one conversation, so the redundant row is dropped.
    func testDropsRedundantParticipationInsteadOfDuplicatingIt() async throws {
        let survivor = PersonBuilder().withEmail(Self.alice).withDisplayName("Alice Smith").build(in: context)
        let loser = PersonBuilder().withEmail(Self.alice).noDisplayName().build(in: context)

        let shared = ConversationBuilder().withParticipantHash("hash-shared").visible().build(in: context)
        addParticipant(person: survivor, to: shared)
        addParticipant(person: loser, to: shared)
        try context.save()

        await makeService().mergeDuplicatePersons(in: context)

        XCTAssertEqual(try personRows(forEmail: Self.alice).count, 1)
        let participants = try context.fetch(ConversationParticipant.fetchRequest())
        XCTAssertEqual(participants.count, 1, "One person must appear once in a conversation")
    }

    /// Message participations move too, and a same-message/same-role row is
    /// likewise collapsed rather than duplicated.
    func testMovesMessageParticipationsAndCollapsesRedundantOnes() async throws {
        let survivor = PersonBuilder().withEmail(Self.alice).withDisplayName("Alice Smith").build(in: context)
        let loser = PersonBuilder().withEmail(Self.alice).noDisplayName().build(in: context)

        let conversation = ConversationBuilder().withParticipantHash("hash-msg").visible().build(in: context)
        let shared = MessageBuilder().withId("msg-shared").inConversation(conversation).build(in: context)
        let loserOnly = MessageBuilder().withId("msg-loser-only").inConversation(conversation).build(in: context)

        addMessageParticipant(person: survivor, to: shared)
        addMessageParticipant(person: loser, to: shared)
        addMessageParticipant(person: loser, to: loserOnly)
        try context.save()

        await makeService().mergeDuplicatePersons(in: context)

        let rows = try personRows(forEmail: Self.alice)
        XCTAssertEqual(rows.count, 1)
        let merged = try XCTUnwrap(rows.first)

        let participations = try context.fetch(MessageParticipant.fetchRequest())
        XCTAssertEqual(participations.count, 2, "The redundant same-message row collapses; the unique one survives")
        XCTAssertTrue(participations.allSatisfy { $0.person === merged })
        XCTAssertEqual(
            Set(participations.compactMap { $0.message?.id }),
            ["msg-shared", "msg-loser-only"]
        )
    }

    /// Rows written before PersonFactory normalized its input differ only by
    /// case. They must merge, and the survivor must end up normalized —
    /// otherwise the `email == %@` lookup still misses it and immediately
    /// creates a third row.
    func testMergesCaseVariantRowsAndNormalizesTheSurvivor() async throws {
        PersonBuilder().withEmail("Alice@Example.com").withDisplayName("Alice Smith").build(in: context)
        PersonBuilder().withEmail(Self.alice).noDisplayName().build(in: context)
        try context.save()

        await makeService().mergeDuplicatePersons(in: context)

        let all = try context.fetch(Person.fetchRequest())
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all.first?.email, Self.alice, "The survivor must carry the normalized address")
    }

    /// The survivor keeps identity the loser held: a name-less winner would
    /// regress display back to a raw address.
    func testSurvivorAdoptsIdentityFieldsFromTheLoser() async throws {
        PersonBuilder().withEmail(Self.alice).withDisplayName("Alice Smith").withAvatarURL(nil).build(in: context)
        PersonBuilder().withEmail(Self.alice).noDisplayName().withAvatarURL("https://example.com/a.png").build(in: context)
        try context.save()

        await makeService().mergeDuplicatePersons(in: context)

        let merged = try XCTUnwrap(try personRows(forEmail: Self.alice).first)
        XCTAssertEqual(merged.displayName, "Alice Smith")
        XCTAssertEqual(merged.avatarURL, "https://example.com/a.png", "An avatar only the loser had must carry across")
    }

    /// Rerunning must be a no-op rather than picking a different survivor.
    func testRerunIsStable() async throws {
        PersonBuilder().withEmail(Self.alice).withDisplayName("Alice Smith").build(in: context)
        PersonBuilder().withEmail(Self.alice).noDisplayName().build(in: context)
        PersonBuilder().withEmail("bob@example.com").withDisplayName("Bob").build(in: context)
        try context.save()

        let service = makeService()
        await service.mergeDuplicatePersons(in: context)
        let firstPass = try personRows(forEmail: Self.alice)
        XCTAssertEqual(firstPass.count, 1)
        let survivorID = try XCTUnwrap(firstPass.first).objectID

        await service.mergeDuplicatePersons(in: context)
        let secondPass = try personRows(forEmail: Self.alice)
        XCTAssertEqual(secondPass.count, 1)
        XCTAssertEqual(secondPass.first?.objectID, survivorID, "A rerun must not swap the survivor")
        XCTAssertEqual(try personRows(forEmail: "bob@example.com").count, 1, "Unique rows are untouched")
    }
}
