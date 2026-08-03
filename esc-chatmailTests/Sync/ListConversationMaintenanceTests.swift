import XCTest
import CoreData
@testable import esc_chatmail

/// Pins how the recurring maintenance passes treat mailing-list conversations,
/// whose participantHash is the "l|" List-Id hash rather than a participant-set
/// derivation.
final class ListConversationMaintenanceTests: XCTestCase {
    private var stack: TestCoreDataStack!
    private var coreDataStack: CoreDataStack!
    private var context: NSManagedObjectContext!

    private static let me = "me@example.com"
    private static let alice = "alice@example.com"
    private static let listAddress = "announce@list.example.com"
    private static let listHash = calculateListConversationHash(fromNormalizedListId: "announce.list.example.com")
    private static let participantHashForRowSet = calculateParticipantHash(from: [alice, listAddress])

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

    /// The hash-fix pass recomputes participant-set hashes from rows. A list
    /// conversation's rows would yield a "p|" hash that both clobbers the list
    /// key and collides with a legitimate participant chat for the same set —
    /// it must be skipped entirely.
    func testFixAndMergeLeavesListConversationsUntouched() async throws {
        let listConversation = ConversationBuilder()
            .withParticipantHash(Self.listHash)
            .withListId("announce.list.example.com")
            .asList()
            .withLastMessageDate(Date(timeIntervalSince1970: 200))
            .visible()
            .build(in: context)
        addConversationParticipant(email: Self.alice, to: listConversation)
        addConversationParticipant(email: Self.listAddress, to: listConversation)
        let listConversationID = listConversation.id

        let participantConversation = ConversationBuilder()
            .withParticipantHash(Self.participantHashForRowSet)
            .withLastMessageDate(Date(timeIntervalSince1970: 100))
            .visible()
            .build(in: context)
        addConversationParticipant(email: Self.alice, to: participantConversation)
        addConversationParticipant(email: Self.listAddress, to: participantConversation)
        let participantConversationID = participantConversation.id

        try context.save()

        let service = DataCleanupService(
            coreDataStack: coreDataStack,
            conversationManager: ConversationManager(currentUserEmail: { Self.me }),
            migrationFlags: InMemoryMigrationFlagStore(),
            identityAliasProvider: { _ in [Self.me] }
        )
        await service.fixAndMergeIncorrectParticipantHashes(in: coreDataStack.newBackgroundContext())

        let states = try fetchConversationStates()
        XCTAssertEqual(states.count, 2, "The list chat must not be merged into the participant chat")
        let listState = try XCTUnwrap(states.first { $0.id == listConversationID })
        XCTAssertEqual(listState.participantHash, Self.listHash, "The l| hash must survive the hash-fix pass")
        let participantState = try XCTUnwrap(states.first { $0.id == participantConversationID })
        XCTAssertEqual(participantState.participantHash, Self.participantHashForRowSet)
    }

    /// Duplicate actives sharing one "l|" hash collapse via the stored-hash
    /// merge — the same reconciliation participant chats get.
    func testDuplicateActiveListConversationsMergeByStoredHash() async throws {
        let older = ConversationBuilder()
            .withParticipantHash(Self.listHash)
            .withListId("announce.list.example.com")
            .asList()
            .withLastMessageDate(Date(timeIntervalSince1970: 100))
            .visible()
            .build(in: context)
        let newer = ConversationBuilder()
            .withParticipantHash(Self.listHash)
            .withListId("announce.list.example.com")
            .asList()
            .withLastMessageDate(Date(timeIntervalSince1970: 200))
            .visible()
            .build(in: context)
        MessageBuilder().withId("msg-old").withDate(Date(timeIntervalSince1970: 100)).inConversation(older).build(in: context)
        MessageBuilder().withId("msg-new").withDate(Date(timeIntervalSince1970: 200)).inConversation(newer).build(in: context)
        try context.save()

        let merger = ConversationMerger(coreDataStack: coreDataStack)
        await merger.mergeActiveConversationDuplicates(in: coreDataStack.newBackgroundContext())

        let states = try fetchConversationStates()
        XCTAssertEqual(states.count, 1)
        let merged = try XCTUnwrap(states.first)
        XCTAssertEqual(merged.participantHash, Self.listHash)
        XCTAssertEqual(merged.messageIDs, ["msg-old", "msg-new"])
    }

    // MARK: - Helpers

    private func addConversationParticipant(email: String, to conversation: Conversation) {
        let person = PersonBuilder()
            .withEmail(email)
            .noDisplayName()
            .build(in: context)
        let participant = context.insertTestObject(ConversationParticipant.self)
        participant.id = UUID()
        participant.role = ParticipantRole.normal.rawValue
        participant.person = person
        participant.conversation = conversation
    }

    private struct ConversationState {
        let id: UUID
        let participantHash: String?
        let messageIDs: Set<String>
    }

    /// Snapshots every conversation from a fresh context so assertions observe
    /// persisted store state.
    private func fetchConversationStates() throws -> [ConversationState] {
        let fetchContext = stack.newBackgroundContext()
        return try fetchContext.performAndWait {
            let request = Conversation.fetchRequest()
            request.relationshipKeyPathsForPrefetching = ["messages"]
            return try fetchContext.fetch(request).map { conversation in
                ConversationState(
                    id: conversation.id,
                    participantHash: conversation.participantHash,
                    messageIDs: Set((conversation.messages ?? []).map(\.id))
                )
            }
        }
    }
}
