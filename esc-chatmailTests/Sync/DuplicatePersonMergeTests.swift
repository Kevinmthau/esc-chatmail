import XCTest
import CoreData
@testable import esc_chatmail

/// Pins the duplicate-Person merge pass. `Person.email` has no uniqueness
/// constraint and the conversation creation serializer's dedicated shell
/// context cannot see a Person still pending in the caller's batch, so
/// duplicate rows for one address are produced routinely; this pass is what
/// keeps them from being permanent.
///
/// Fixtures, saves, and assertions go through a main-queue context from
/// `TestCoreDataStack.makeMainQueueViewContext()`, never `stack.viewContext`,
/// which is private-queue. The test bodies use it directly, so `@MainActor` on
/// the class is what puts those accesses on-queue; see that helper for what the
/// private-queue shape races.
///
/// HONEST SCOPE: no test here can reproduce that race on demand. With
/// `-com.apple.CoreData.ConcurrencyDebug 1` the old shape traps and this shape
/// runs clean.
@MainActor
final class DuplicatePersonMergeTests: XCTestCase {
    private var stack: TestCoreDataStack!
    private var coreDataStack: CoreDataStack!
    private var context: NSManagedObjectContext!

    private nonisolated static let me = "me@example.com"
    private static let alice = "alice@example.com"

    override func setUp() {
        super.setUp()
        stack = TestCoreDataStack()
        coreDataStack = CoreDataStack(persistentContainerForTesting: stack.persistentContainer)
        context = stack.makeMainQueueViewContext()
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
    /// than stranding a participant-less conversation.
    ///
    /// Revert-check: the repoint-before-delete order in
    /// `DataCleanupService.mergeDuplicatePersons`. Delete the loser before its
    /// repoint and the repoint's first fetch processes the delete, whose
    /// cascade takes the loser's participant row: 1 participant instead of 2.
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
    ///
    /// Revert-check: the repoint-before-delete order in
    /// `DataCleanupService.mergeDuplicatePersons`. Delete the loser before its
    /// repoint and the repoint's first fetch processes the delete, whose
    /// cascade takes `msg-loser-only`'s row with it.
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

    /// The participations are read by fetches
    /// (`DataCleanupService.messageParticipations(of:prefetchingMessages:in:)`), not through
    /// `Person.messageParticipations`, which model 9 drops, and a fetch can
    /// fail. A loser whose participations could not be read must not be
    /// deleted: its cascade would take them along, and the messages would lose
    /// their participant rows. Both rows stay for the next cleanup.
    ///
    /// Revert-check: the `continue` in `mergeDuplicatePersons`' catch. Fall
    /// through to the delete and the loser goes with its participation.
    func testParticipationFetchFails_keepsTheLoserAndItsParticipations() async throws {
        let survivor = PersonBuilder().withEmail(Self.alice).withDisplayName("Alice Smith").build(in: context)
        let loser = PersonBuilder().withEmail(Self.alice).noDisplayName().build(in: context)
        let conversation = ConversationBuilder().withParticipantHash("hash-fetch-fails").visible().build(in: context)
        let message = MessageBuilder().withId("msg-fetch-fails").inConversation(conversation).build(in: context)
        addMessageParticipant(person: survivor, to: message, kind: "to")
        addMessageParticipant(person: loser, to: message, kind: "from")
        try context.save()
        let loserID = loser.objectID
        let failingContext = EntityFetchFailingContext(
            failingEntityName: "MessageParticipant",
            coordinator: stack.persistentContainer.persistentStoreCoordinator,
            concurrencyType: .mainQueueConcurrencyType
        )

        await makeService().mergeDuplicatePersons(in: failingContext)

        XCTAssertEqual(failingContext.failedFetches, 1)
        context.refreshAllObjects()
        XCTAssertEqual(try personRows(forEmail: Self.alice).count, 2)
        let participations = try context.fetch(MessageParticipant.fetchRequest())
        XCTAssertEqual(participations.count, 2, "The loser's participation was deleted with it")
        XCTAssertEqual(
            participations.first { $0.kind == "from" }?.person?.objectID,
            loserID,
            "Nothing is moved when the reads fail"
        )
    }

    /// Three rows for one address, and both losers are the sender of the same
    /// message: the first loser's row moves onto the survivor, and the second
    /// loser's check must see that unsaved move and drop its own row, or the
    /// message lists the sender twice. The survivor's participations are read
    /// as this context has them (`DataCleanupService.messageParticipationKeys`).
    ///
    /// Revert-check: the in-memory `participation.person` filter in
    /// `messageParticipationKeys(of:among:in:)`. Filter on the stored person
    /// (`committedValues(forKeys: ["person"])`) and the second loser's row is
    /// moved too: two `from` rows on the message.
    func testTwoLosersOnOneMessage_collapseToOneRowOnTheSurvivor() async throws {
        let survivor = PersonBuilder().withEmail(Self.alice).withDisplayName("Alice Smith").build(in: context)
        let firstLoser = PersonBuilder().withEmail(Self.alice).noDisplayName().build(in: context)
        let secondLoser = PersonBuilder().withEmail(Self.alice).noDisplayName().build(in: context)
        let conversation = ConversationBuilder().withParticipantHash("hash-two-losers").visible().build(in: context)
        let message = MessageBuilder().withId("msg-two-losers").inConversation(conversation).build(in: context)
        addMessageParticipant(person: firstLoser, to: message, kind: "from")
        addMessageParticipant(person: secondLoser, to: message, kind: "from")
        try context.save()

        await makeService().mergeDuplicatePersons(in: context)

        let rows = try personRows(forEmail: Self.alice)
        XCTAssertEqual(rows.map(\.objectID), [survivor.objectID])
        let participations = try context.fetch(MessageParticipant.fetchRequest())
        XCTAssertEqual(participations.count, 1, "The sender is listed once on the message")
        XCTAssertEqual(participations.first?.person?.objectID, survivor.objectID)
        XCTAssertEqual(participations.first?.kind, "from")
    }

    /// The survivor's participations are the merge's second read. When it
    /// fails, nothing has moved yet: both rows stay, every participation stays
    /// where it was, and the context is left with no changes for a later save
    /// to commit.
    ///
    /// Revert-check: the survivor read ahead of the conversation repoint in
    /// `repointParticipations`. Read it after the loser's conversation
    /// participation was moved and the failure leaves that move in the
    /// context.
    func testSurvivorParticipationFetchFails_keepsBothRowsAndChangesNothing() async throws {
        let survivor = PersonBuilder().withEmail(Self.alice).withDisplayName("Alice Smith").build(in: context)
        let loser = PersonBuilder().withEmail(Self.alice).noDisplayName().build(in: context)
        let conversation = ConversationBuilder().withParticipantHash("hash-second-read").visible().build(in: context)
        let message = MessageBuilder().withId("msg-second-read").inConversation(conversation).build(in: context)
        addParticipant(person: loser, to: conversation)
        addMessageParticipant(person: survivor, to: message, kind: "to")
        addMessageParticipant(person: loser, to: message, kind: "from")
        let otherMessage = MessageBuilder().withId("msg-second-read-2").inConversation(conversation).build(in: context)
        addMessageParticipant(person: loser, to: otherMessage, kind: "from")
        try context.save()
        let loserID = loser.objectID
        let failingContext = EntityFetchFailingContext(
            failingEntityName: "MessageParticipant",
            coordinator: stack.persistentContainer.persistentStoreCoordinator,
            concurrencyType: .mainQueueConcurrencyType,
            succeedingFirst: 1
        )

        await makeService().mergeDuplicatePersons(in: failingContext)

        XCTAssertEqual(failingContext.failedFetches, 1)
        XCTAssertFalse(failingContext.hasChanges, "A failed read left a partial merge in the context")
        context.refreshAllObjects()
        XCTAssertEqual(try personRows(forEmail: Self.alice).count, 2)
        let participations = try context.fetch(MessageParticipant.fetchRequest())
        XCTAssertEqual(participations.count, 3)
        XCTAssertEqual(
            Set(participations.filter { $0.kind == "from" }.compactMap { $0.person?.objectID }),
            [loserID]
        )
        let conversationParticipants = try context.fetch(ConversationParticipant.fetchRequest())
        XCTAssertEqual(conversationParticipants.map { $0.person?.objectID }, [loserID])
    }

    /// The survivor's participations are read a chunk of messages at a time
    /// (`DataCleanupService.messageParticipationKeys`), and every chunk is
    /// asked, the last, partial one included; another person's rows on the
    /// same messages are not the survivor's.
    ///
    /// Revert-check: the partial last chunk in `messageParticipationKeys`
    /// (`min(start + chunkSize, messages.count)`). Ask only whole chunks and
    /// the fifth message's row is missed.
    ///
    /// HONEST SCOPE: what the chunks are for, a bounded peak for a heavy
    /// Person's duplicate, is not measured here.
    func testSurvivorParticipationKeys_askEveryChunk() throws {
        let survivor = PersonBuilder().withEmail(Self.alice).withDisplayName("Alice Smith").build(in: context)
        let other = PersonBuilder().withEmail("bob@example.com").withDisplayName("Bob").build(in: context)
        let conversation = ConversationBuilder().withParticipantHash("hash-chunks").visible().build(in: context)
        let messages = (0..<5).map { index in
            MessageBuilder().withId("msg-chunk-\(index)").inConversation(conversation).build(in: context)
        }
        for message in messages {
            addMessageParticipant(person: survivor, to: message, kind: "to")
            addMessageParticipant(person: other, to: message, kind: "from")
        }
        try context.save()

        let chunked = try DataCleanupService.messageParticipationKeys(of: survivor, among: messages, chunkSize: 2, in: context)
        let whole = try DataCleanupService.messageParticipationKeys(of: survivor, among: messages, chunkSize: 300, in: context)

        XCTAssertEqual(chunked.count, 5)
        XCTAssertEqual(chunked, whole)
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

    /// Of a named row and a duplicate holding the address as its name, the
    /// named row survives and keeps its name, whichever the fetch yields first.
    ///
    /// Revert-check: removing the `isEmailAddressShapedDisplayName` guard in
    /// `EmailNormalizer.isBetterDisplayName(_:than:forEmail:)` fails this test
    /// in either fetch order. Both rankings said yes, so `survivingPerson` took
    /// the later row: the address row (survivor assertion), or the named row,
    /// over which `adoptMissingIdentityFields` then copied the address (name
    /// assertion).
    func testAddressShapedDuplicateNameNeverOverwritesRealName() async throws {
        let email = "jacob.laycock@studs.com"
        PersonBuilder().withEmail(email).withDisplayName(email).build(in: context)
        let named = PersonBuilder().withEmail(email).withDisplayName("Jacob Laycock").build(in: context)
        try context.save()
        let namedID = named.objectID

        await makeService().mergeDuplicatePersons(in: context)

        let rows = try personRows(forEmail: email)
        XCTAssertEqual(rows.map(\.objectID), [namedID], "The named row must survive")
        XCTAssertEqual(rows.map(\.displayName), ["Jacob Laycock"])
    }

    /// Of a row with a real name and a duplicate whose name matches the address
    /// at the same part count, the real-named row survives and keeps its name,
    /// whichever the fetch yields first.
    ///
    /// Revert-check: removing the part-count `guard` from the derived-candidate
    /// branch of `EmailNormalizer.isBetterDisplayName(_:than:forEmail:)` fails
    /// this test in either fetch order, the same way the address-shaped case
    /// above did: `survivingPerson` took the later row, and
    /// `adoptMissingIdentityFields` copied the other row's name onto it.
    func testAddressDerivedDuplicateNameNeverOverwritesRealNameOfEqualPartCount() async throws {
        let email = "jacob.laycock@studs.com"
        PersonBuilder().withEmail(email).withDisplayName("Jacob Laycock").build(in: context)
        let named = PersonBuilder().withEmail(email).withDisplayName("Jake Laycock").build(in: context)
        try context.save()
        let namedID = named.objectID

        await makeService().mergeDuplicatePersons(in: context)

        let rows = try personRows(forEmail: email)
        XCTAssertEqual(rows.map(\.objectID), [namedID], "The real-named row must survive")
        XCTAssertEqual(rows.map(\.displayName), ["Jake Laycock"])
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
