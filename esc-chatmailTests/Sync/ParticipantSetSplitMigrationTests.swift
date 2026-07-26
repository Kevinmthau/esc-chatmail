import XCTest
import CoreData
@testable import esc_chatmail

/// Covers `DataCleanupService.splitConversationsByParticipantSetIfNeeded`, the
/// one-shot migration that re-homes every message into the conversation keyed
/// by its strict participant set (From+To+Cc minus the user's aliases).
final class ParticipantSetSplitMigrationTests: XCTestCase {
    private var stack: TestCoreDataStack!
    private var coreDataStack: CoreDataStack!
    private var context: NSManagedObjectContext!
    private var migrationFlags: InMemoryMigrationFlagStore!

    private static let me = "me@example.com"
    private static let alice = "alice@example.com"
    private static let bob = "bob@example.com"
    private static let carol = "carol@example.com"

    private static let hashAlice = calculateParticipantHash(from: [alice])
    private static let hashAliceBob = calculateParticipantHash(from: [alice, bob])
    private static let hashAliceCarol = calculateParticipantHash(from: [alice, carol])
    private static let hashBob = calculateParticipantHash(from: [bob])
    private static let hashCarol = calculateParticipantHash(from: [carol])

    override func setUp() {
        super.setUp()
        stack = TestCoreDataStack()
        coreDataStack = CoreDataStack(persistentContainerForTesting: stack.persistentContainer)
        context = stack.viewContext
        migrationFlags = InMemoryMigrationFlagStore()
    }

    override func tearDown() {
        migrationFlags = nil
        context = nil
        coreDataStack = nil
        stack = nil
        super.tearDown()
    }

    // MARK: - Tests

    func testMixedParticipantThreadSplitsIntoStrictSetChats() async throws {
        let inbox = LabelBuilder().inbox().build(in: context)
        let lumped = ConversationBuilder()
            .withParticipantHash(Self.hashAlice)
            .withLastMessageDate(Date(timeIntervalSince1970: 300))
            .visible()
            .build(in: context)
        let lumpedID = lumped.id

        // One Gmail thread whose recipients changed mid-thread: three strict sets.
        try addMessage(
            id: "msg-a", date: Date(timeIntervalSince1970: 100),
            from: Self.alice, to: [Self.me],
            labels: [inbox], threadId: "thread-1", in: lumped
        )
        try addMessage(
            id: "msg-ab", date: Date(timeIntervalSince1970: 200),
            from: Self.alice, to: [Self.me, Self.bob],
            labels: [inbox], threadId: "thread-1", in: lumped
        )
        try addMessage(
            id: "msg-ac", date: Date(timeIntervalSince1970: 300),
            from: Self.alice, to: [Self.me, Self.carol],
            labels: [inbox], threadId: "thread-1", in: lumped
        )
        try context.save()

        await runMigration()

        let states = try fetchConversationStates()
        XCTAssertEqual(states.count, 3)

        let aliceState = try state(Self.hashAlice, in: states)
        XCTAssertEqual(
            aliceState.id, lumpedID,
            "The {alice} messages must stay in the original conversation"
        )
        XCTAssertEqual(aliceState.messageIDs, ["msg-a"])
        XCTAssertEqual(try state(Self.hashAliceBob, in: states).messageIDs, ["msg-ab"])
        XCTAssertEqual(try state(Self.hashAliceCarol, in: states).messageIDs, ["msg-ac"])
        XCTAssertTrue(migrationFlags.bool(forKey: DataCleanupService.participantSetSplitMigrationKey))
    }

    func testSameParticipantSetAcrossThreadsMergesIntoOneActiveChat() async throws {
        let inbox = LabelBuilder().inbox().build(in: context)
        let firstThread = ConversationBuilder()
            .withParticipantHash(Self.hashAlice)
            .withLastMessageDate(Date(timeIntervalSince1970: 100))
            .visible()
            .build(in: context)
        let secondThread = ConversationBuilder()
            .withParticipantHash(Self.hashAlice)
            .withLastMessageDate(Date(timeIntervalSince1970: 200))
            .visible()
            .build(in: context)

        try addMessage(
            id: "msg-thread-1", date: Date(timeIntervalSince1970: 100),
            from: Self.alice, to: [Self.me],
            labels: [inbox], threadId: "thread-1", in: firstThread
        )
        try addMessage(
            id: "msg-thread-2", date: Date(timeIntervalSince1970: 200),
            from: Self.alice, to: [Self.me],
            labels: [inbox], threadId: "thread-2", in: secondThread
        )
        try context.save()

        await runMigration()

        // The re-home skip rule keeps both epochs' messages in place; the
        // migration's duplicate-active merge is what collapses the two rows.
        let states = try fetchConversationStates()
        XCTAssertEqual(states.count, 1)
        let merged = try XCTUnwrap(states.first)
        XCTAssertEqual(merged.participantHash, Self.hashAlice)
        XCTAssertNil(merged.archivedAt)
        XCTAssertEqual(merged.messageIDs, ["msg-thread-1", "msg-thread-2"])
    }

    func testRollupsAndUnreadCountsCorrectAfterSplit() async throws {
        let inbox = LabelBuilder().inbox().build(in: context)
        let lumped = ConversationBuilder()
            .withParticipantHash(Self.hashAlice)
            .withUnreadCount(5)
            .withLastMessageDate(Date(timeIntervalSince1970: 200))
            .visible()
            .build(in: context)

        try addMessage(
            id: "msg-a-unread", date: Date(timeIntervalSince1970: 100),
            from: Self.alice, to: [Self.me],
            unread: true, labels: [inbox], in: lumped
        )
        try addMessage(
            id: "msg-ab-unread", date: Date(timeIntervalSince1970: 200),
            from: Self.alice, to: [Self.me, Self.bob],
            unread: true, labels: [inbox], in: lumped
        )
        // Old, read, non-INBOX incoming mail: its split-out chat must land archived.
        try addMessage(
            id: "msg-c-old", date: Date(timeIntervalSince1970: 50),
            from: Self.carol, to: [Self.me],
            in: lumped
        )
        try context.save()

        await runMigration()

        let states = try fetchConversationStates()
        XCTAssertEqual(states.count, 3)

        let aliceState = try state(Self.hashAlice, in: states)
        XCTAssertTrue(aliceState.hasInbox)
        XCTAssertEqual(aliceState.inboxUnreadCount, 1)
        XCTAssertEqual(aliceState.lastMessageDate, Date(timeIntervalSince1970: 100))
        XCTAssertNil(aliceState.archivedAt)

        let aliceBobState = try state(Self.hashAliceBob, in: states)
        XCTAssertTrue(aliceBobState.hasInbox)
        XCTAssertEqual(aliceBobState.inboxUnreadCount, 1)
        XCTAssertEqual(aliceBobState.lastMessageDate, Date(timeIntervalSince1970: 200))
        XCTAssertNil(aliceBobState.archivedAt)

        let carolState = try state(Self.hashCarol, in: states)
        XCTAssertFalse(carolState.hasInbox)
        XCTAssertEqual(carolState.inboxUnreadCount, 0)
        XCTAssertEqual(carolState.lastMessageDate, Date(timeIntervalSince1970: 50))
        XCTAssertNotNil(
            carolState.archivedAt,
            "A split-out conversation holding only old non-INBOX mail must land archived"
        )
    }

    func testArchivedEpochWithMatchingHashKeepsItsMessages() async throws {
        let inbox = LabelBuilder().inbox().build(in: context)
        let archivedDate = Date(timeIntervalSince1970: 500)
        let archivedEpoch = ConversationBuilder()
            .withParticipantHash(Self.hashAlice)
            .withLastMessageDate(Date(timeIntervalSince1970: 100))
            .archivedOn(archivedDate)
            .build(in: context)
        let activeEpoch = ConversationBuilder()
            .withParticipantHash(Self.hashAlice)
            .withLastMessageDate(Date(timeIntervalSince1970: 200))
            .visible()
            .build(in: context)
        let archivedID = archivedEpoch.id
        let activeID = activeEpoch.id

        try addMessage(
            id: "msg-old-epoch", date: Date(timeIntervalSince1970: 100),
            from: Self.alice, to: [Self.me],
            in: archivedEpoch
        )
        try addMessage(
            id: "msg-new-epoch", date: Date(timeIntervalSince1970: 200),
            from: Self.alice, to: [Self.me],
            labels: [inbox], in: activeEpoch
        )
        try context.save()

        await runMigration()

        // The archived epoch already carries its messages' strict hash, so the
        // re-home skip rule leaves it alone, and the duplicate-active merge
        // only considers active conversations.
        let states = try fetchConversationStates()
        XCTAssertEqual(states.count, 2)

        let archivedState = try XCTUnwrap(states.first { $0.id == archivedID })
        XCTAssertEqual(archivedState.messageIDs, ["msg-old-epoch"])
        XCTAssertEqual(archivedState.archivedAt, archivedDate)

        let activeState = try XCTUnwrap(states.first { $0.id == activeID })
        XCTAssertEqual(activeState.messageIDs, ["msg-new-epoch"])
        XCTAssertNil(activeState.archivedAt)
    }

    func testMisHomedMessageFoldsIntoMostRecentEpochNotNewOne() async throws {
        let inbox = LabelBuilder().inbox().build(in: context)
        let wrongHome = ConversationBuilder()
            .withParticipantHash(Self.hashBob)
            .withLastMessageDate(Date(timeIntervalSince1970: 200))
            .visible()
            .build(in: context)
        let existingAliceChat = ConversationBuilder()
            .withParticipantHash(Self.hashAlice)
            .withLastMessageDate(Date(timeIntervalSince1970: 150))
            .visible()
            .build(in: context)
        let existingAliceID = existingAliceChat.id

        try addMessage(
            id: "msg-b", date: Date(timeIntervalSince1970: 200),
            from: Self.bob, to: [Self.me],
            labels: [inbox], in: wrongHome
        )
        try addMessage(
            id: "msg-mis-homed-a", date: Date(timeIntervalSince1970: 100),
            from: Self.alice, to: [Self.me],
            labels: [inbox], in: wrongHome
        )
        try addMessage(
            id: "msg-a-existing", date: Date(timeIntervalSince1970: 150),
            from: Self.alice, to: [Self.me],
            labels: [inbox], in: existingAliceChat
        )
        try context.save()

        await runMigration()

        let states = try fetchConversationStates()
        XCTAssertEqual(
            states.count, 2,
            "The mis-homed message must fold into the existing {alice} conversation, not a new one"
        )

        let aliceState = try state(Self.hashAlice, in: states)
        XCTAssertEqual(aliceState.id, existingAliceID)
        XCTAssertEqual(aliceState.messageIDs, ["msg-a-existing", "msg-mis-homed-a"])
        XCTAssertEqual(try state(Self.hashBob, in: states).messageIDs, ["msg-b"])
    }

    func testMigrationIsIdempotentAcrossReRun() async throws {
        let inbox = LabelBuilder().inbox().build(in: context)
        let lumped = ConversationBuilder()
            .withParticipantHash(Self.hashAlice)
            .withLastMessageDate(Date(timeIntervalSince1970: 200))
            .visible()
            .build(in: context)

        try addMessage(
            id: "msg-a", date: Date(timeIntervalSince1970: 100),
            from: Self.alice, to: [Self.me],
            labels: [inbox], in: lumped
        )
        try addMessage(
            id: "msg-ab", date: Date(timeIntervalSince1970: 200),
            from: Self.alice, to: [Self.me, Self.bob],
            labels: [inbox], in: lumped
        )
        try context.save()

        await runMigration()
        let firstPass = try fetchConversationStates()
            .sorted { $0.id.uuidString < $1.id.uuidString }
        XCTAssertEqual(firstPass.count, 2)

        // A fresh flag store simulates the flag being lost (reinstall of the
        // defaults suite): a second full pass must not change anything.
        let rerunFlags = InMemoryMigrationFlagStore()
        await runMigration(flags: rerunFlags)
        let secondPass = try fetchConversationStates()
            .sorted { $0.id.uuidString < $1.id.uuidString }

        XCTAssertEqual(firstPass, secondPass)
        XCTAssertTrue(rerunFlags.bool(forKey: DataCleanupService.participantSetSplitMigrationKey))
    }

    func testFlagPreventsReRun() async throws {
        migrationFlags.set(true, forKey: DataCleanupService.participantSetSplitMigrationKey)

        // Obviously-wrong seed: an {alice,bob} message homed in an {alice} chat.
        let lumped = ConversationBuilder()
            .withParticipantHash(Self.hashAlice)
            .withLastMessageDate(Date(timeIntervalSince1970: 100))
            .visible()
            .build(in: context)
        let lumpedID = lumped.id
        try addMessage(
            id: "msg-ab-wrong-home", date: Date(timeIntervalSince1970: 100),
            from: Self.alice, to: [Self.me, Self.bob],
            in: lumped
        )
        try context.save()

        await runMigration()

        let states = try fetchConversationStates()
        XCTAssertEqual(states.count, 1)
        XCTAssertEqual(states.first?.id, lumpedID)
        XCTAssertEqual(states.first?.messageIDs, ["msg-ab-wrong-home"])
    }

    func testEmptyAliasProviderDoesNotBurnFlag() async throws {
        let inbox = LabelBuilder().inbox().build(in: context)
        let lumped = ConversationBuilder()
            .withParticipantHash(Self.hashAlice)
            .withLastMessageDate(Date(timeIntervalSince1970: 200))
            .visible()
            .build(in: context)
        try addMessage(
            id: "msg-a", date: Date(timeIntervalSince1970: 100),
            from: Self.alice, to: [Self.me],
            labels: [inbox], in: lumped
        )
        try addMessage(
            id: "msg-ab", date: Date(timeIntervalSince1970: 200),
            from: Self.alice, to: [Self.me, Self.bob],
            labels: [inbox], in: lumped
        )
        try context.save()

        // Pre-auth launch: no aliases available yet.
        await runMigration(aliases: [])

        XCTAssertFalse(
            migrationFlags.bool(forKey: DataCleanupService.participantSetSplitMigrationKey),
            "An aliasless run must not burn the one-shot flag"
        )
        let untouched = try fetchConversationStates()
        XCTAssertEqual(untouched.count, 1)
        XCTAssertEqual(untouched.first?.messageIDs, ["msg-a", "msg-ab"])

        // Once aliases resolve, the same flag store must still allow the split.
        await runMigration()

        XCTAssertTrue(migrationFlags.bool(forKey: DataCleanupService.participantSetSplitMigrationKey))
        let split = try fetchConversationStates()
        XCTAssertEqual(split.count, 2)
        XCTAssertEqual(try state(Self.hashAliceBob, in: split).messageIDs, ["msg-ab"])
    }

    func testMessageWithoutParticipantDataIsNotMoved() async throws {
        // An optimistic local send: no MessageParticipant rows, no senderEmail,
        // in a conversation whose hash matches nothing derivable.
        let orphanHome = ConversationBuilder()
            .withParticipantHash("legacy-unknown-hash")
            .withLastMessageDate(Date(timeIntervalSince1970: 100))
            .visible()
            .build(in: context)
        let orphanHomeID = orphanHome.id
        let message = MessageBuilder()
            .withId("msg-no-participants")
            .withDate(Date(timeIntervalSince1970: 100))
            .inConversation(orphanHome)
            .build(in: context)
        message.senderEmail = nil
        try context.save()

        await runMigration()

        XCTAssertTrue(migrationFlags.bool(forKey: DataCleanupService.participantSetSplitMigrationKey))
        let states = try fetchConversationStates()
        XCTAssertEqual(states.count, 1)
        XCTAssertEqual(states.first?.id, orphanHomeID)
        XCTAssertEqual(states.first?.messageIDs, ["msg-no-participants"])
    }

    func testEmptiedShellReferencedByPendingSendRecordSurvives() async throws {
        let inbox = LabelBuilder().inbox().build(in: context)
        let staleHashZed = calculateParticipantHash(from: ["zed@example.com"])
        let staleHashYak = calculateParticipantHash(from: ["yak@example.com"])

        let protectedShell = ConversationBuilder()
            .withParticipantHash(staleHashZed)
            .withLastMessageDate(Date(timeIntervalSince1970: 100))
            .visible()
            .build(in: context)
        let unprotectedShell = ConversationBuilder()
            .withParticipantHash(staleHashYak)
            .withLastMessageDate(Date(timeIntervalSince1970: 200))
            .visible()
            .build(in: context)
        let protectedID = protectedShell.id
        let unprotectedID = unprotectedShell.id

        try addMessage(
            id: "msg-protected-move", date: Date(timeIntervalSince1970: 100),
            from: Self.alice, to: [Self.me],
            labels: [inbox], in: protectedShell
        )
        try addMessage(
            id: "msg-unprotected-move", date: Date(timeIntervalSince1970: 200),
            from: Self.alice, to: [Self.me],
            labels: [inbox], in: unprotectedShell
        )

        // An in-flight optimistic send still references the protected shell.
        let record = context.insertTestObject(OutboundSendMutationRecord.self)
        record.id = UUID().uuidString
        record.createdAt = Date()
        record.conversationId = protectedID
        try context.save()

        await runMigration()

        let states = try fetchConversationStates()
        XCTAssertEqual(states.count, 2)

        let protectedState = try XCTUnwrap(
            states.first { $0.id == protectedID },
            "A shell referenced by a pending send record must survive the sweep"
        )
        XCTAssertTrue(protectedState.messageIDs.isEmpty)
        XCTAssertNil(
            states.first { $0.id == unprotectedID },
            "An emptied shell with no pending send must be swept"
        )
        XCTAssertEqual(
            try state(Self.hashAlice, in: states).messageIDs,
            ["msg-protected-move", "msg-unprotected-move"]
        )
    }

    func testParticipantRowsRebuiltToMatchMessages() async throws {
        let inbox = LabelBuilder().inbox().build(in: context)
        let lumped = ConversationBuilder()
            .withParticipantHash(Self.hashAliceBob)
            .withLastMessageDate(Date(timeIntervalSince1970: 200))
            .visible()
            .build(in: context)
        let lumpedID = lumped.id

        // Participant rows carry a stale third person from the thread-merged past.
        addConversationParticipant(email: Self.alice, to: lumped)
        addConversationParticipant(email: Self.bob, to: lumped)
        addConversationParticipant(email: Self.carol, to: lumped)

        try addMessage(
            id: "msg-ab-keeper", date: Date(timeIntervalSince1970: 200),
            from: Self.alice, to: [Self.me, Self.bob],
            labels: [inbox], in: lumped
        )
        // A mover makes the conversation "touched" so the rebuild inspects it.
        try addMessage(
            id: "msg-a-mover", date: Date(timeIntervalSince1970: 100),
            from: Self.alice, to: [Self.me],
            labels: [inbox], in: lumped
        )
        try context.save()

        await runMigration()

        let states = try fetchConversationStates()
        let rebuilt = try XCTUnwrap(states.first { $0.id == lumpedID })
        XCTAssertEqual(rebuilt.messageIDs, ["msg-ab-keeper"])
        XCTAssertEqual(
            rebuilt.participantEmails, [Self.alice, Self.bob],
            "Stale participant rows must be rebuilt from message-derived identity"
        )
        XCTAssertEqual(rebuilt.typeRaw, ConversationType.group.rawValue)
        XCTAssertEqual(try state(Self.hashAlice, in: states).messageIDs, ["msg-a-mover"])
    }

    func testRowlessSentMessageIsNotRehomedToSelfChat() async throws {
        let inbox = LabelBuilder().inbox().build(in: context)
        let aliceChat = ConversationBuilder()
            .withParticipantHash(Self.hashAlice)
            .withLastMessageDate(Date(timeIntervalSince1970: 200))
            .visible()
            .build(in: context)
        let aliceChatID = aliceChat.id

        try addMessage(
            id: "msg-a", date: Date(timeIntervalSince1970: 100),
            from: Self.alice, to: [Self.me],
            labels: [inbox], in: aliceChat
        )
        // A reconciled optimistic send: participant rows were never written and
        // senderEmail is the user's own address. Deriving identity from it would
        // collapse the user's sent bubbles into the note-to-self chat.
        let sent = MessageBuilder()
            .withId("msg-sent-rowless")
            .withDate(Date(timeIntervalSince1970: 200))
            .withSender(email: Self.me)
            .inConversation(aliceChat)
            .build(in: context)
        sent.isFromMe = true
        try context.save()

        await runMigration()

        let states = try fetchConversationStates()
        XCTAssertEqual(states.count, 1, "A row-less sent message must not spawn or join a self-chat")
        XCTAssertEqual(states.first?.id, aliceChatID)
        XCTAssertEqual(states.first?.messageIDs, ["msg-a", "msg-sent-rowless"])
    }

    func testStrandedDrainedShellFromPriorAbortedRunIsSwept() async throws {
        // Shape left by a crash between an interim Phase-1 save and the sweep:
        // an empty, stale-hashed shell that still carries participant rows (so
        // the generic empty-conversation cleanup can never match it) and that a
        // re-run's re-home never touches (no movers remain).
        let strandedShell = ConversationBuilder()
            .withParticipantHash("stale-drained-hash")
            .withCreatedAt(Date(timeIntervalSince1970: 100))
            .withLastMessageDate(Date(timeIntervalSince1970: 100))
            .visible()
            .build(in: context)
        addConversationParticipant(email: Self.bob, to: strandedShell)
        let strandedID = strandedShell.id

        let aliceChat = ConversationBuilder()
            .withParticipantHash(Self.hashAlice)
            .withLastMessageDate(Date(timeIntervalSince1970: 200))
            .visible()
            .build(in: context)
        try addMessage(
            id: "msg-a", date: Date(timeIntervalSince1970: 200),
            from: Self.alice, to: [Self.me], in: aliceChat
        )
        try context.save()

        await runMigration()

        let states = try fetchConversationStates()
        XCTAssertNil(
            states.first { $0.id == strandedID },
            "A drained shell left by an aborted run must be swept even though this run re-homes nothing into or out of it"
        )
    }

    func testPinnedStateFollowsFullyDrainedShellToDestination() async throws {
        let inbox = LabelBuilder().inbox().build(in: context)
        // The user pinned this chat; its stored identity was wrong, so the
        // migration drains it entirely into the strict {alice} conversation.
        let pinnedShell = ConversationBuilder()
            .withParticipantHash("stale-pinned-hash")
            .withCreatedAt(Date(timeIntervalSince1970: 100))
            .withLastMessageDate(Date(timeIntervalSince1970: 100))
            .visible()
            .build(in: context)
        pinnedShell.pinned = true
        let pinnedShellID = pinnedShell.id

        try addMessage(
            id: "msg-a-pinned", date: Date(timeIntervalSince1970: 100),
            from: Self.alice, to: [Self.me],
            labels: [inbox], in: pinnedShell
        )
        try context.save()

        await runMigration()

        let states = try fetchConversationStates()
        XCTAssertNil(states.first { $0.id == pinnedShellID })
        let aliceState = try state(Self.hashAlice, in: states)
        XCTAssertEqual(aliceState.messageIDs, ["msg-a-pinned"])
        XCTAssertTrue(
            aliceState.pinned,
            "Pinned state must follow a fully-drained shell to where its messages went"
        )
    }

    func testCorrectlyHomedListMessagesAreNotYankedByMigration() async throws {
        // Fresh installs run this migration after list grouping is live: a
        // list message's strict identity must match its conversation's "l|"
        // hash, or Phase 1 yanks list mail back out into participant chats.
        let listId = "announce.lists.example.com"
        let listHash = calculateListConversationHash(fromNormalizedListId: listId)
        let inbox = LabelBuilder().inbox().build(in: context)
        let listConversation = ConversationBuilder()
            .withParticipantHash(listHash)
            .withListId(listId)
            .asList()
            .withLastMessageDate(Date(timeIntervalSince1970: 100))
            .visible()
            .build(in: context)
        let listConversationID = listConversation.id

        let message = try addMessage(
            id: "msg-list", date: Date(timeIntervalSince1970: 100),
            from: Self.alice, to: [Self.me],
            labels: [inbox], in: listConversation
        )
        message.listId = listId
        try context.save()

        await runMigration()

        XCTAssertTrue(migrationFlags.bool(forKey: DataCleanupService.participantSetSplitMigrationKey))
        let states = try fetchConversationStates()
        XCTAssertEqual(states.count, 1, "A correctly-homed list message must not be re-homed")
        XCTAssertEqual(states.first?.id, listConversationID)
        XCTAssertEqual(states.first?.messageIDs, ["msg-list"])
        XCTAssertEqual(states.first?.participantHash, listHash)
    }

    func testMisHomedListMessageMintsListDestination() async throws {
        // A list message stranded in a participant chat (the pre-flip shape on
        // a fresh install mid-sync) must move to a freshly minted list
        // conversation carrying the "l|" hash, .list type, and the listId.
        let listId = "announce.lists.example.com"
        let listHash = calculateListConversationHash(fromNormalizedListId: listId)
        let inbox = LabelBuilder().inbox().build(in: context)
        let lumped = ConversationBuilder()
            .withParticipantHash(Self.hashAlice)
            .withLastMessageDate(Date(timeIntervalSince1970: 200))
            .visible()
            .build(in: context)
        let lumpedID = lumped.id

        try addMessage(
            id: "msg-a", date: Date(timeIntervalSince1970: 100),
            from: Self.alice, to: [Self.me],
            labels: [inbox], in: lumped
        )
        let listMessage = try addMessage(
            id: "msg-list", date: Date(timeIntervalSince1970: 200),
            from: Self.alice, to: [Self.me],
            labels: [inbox], in: lumped
        )
        listMessage.listId = listId
        try context.save()

        await runMigration()

        let states = try fetchConversationStates()
        XCTAssertEqual(states.count, 2)
        let aliceState = try XCTUnwrap(states.first { $0.id == lumpedID })
        XCTAssertEqual(aliceState.messageIDs, ["msg-a"])
        let listState = try state(listHash, in: states)
        XCTAssertEqual(listState.messageIDs, ["msg-list"])
        XCTAssertEqual(listState.typeRaw, ConversationType.list.rawValue)
        XCTAssertEqual(listState.listId, listId)
    }

    func testTouchedListConversationKeepsCreationSeededRows() async throws {
        // Phase 2c rebuilds a touched conversation's rows from any one message
        // sharing its hash — sound for "p|" chats, where one hash implies one
        // participant set, but unsound for "l|" chats, whose members vary per
        // message: the rebuild would copy whichever message the unordered
        // relationship yields first. List rows seed once at creation and must
        // survive the pass. The stored row here deliberately matches NEITHER
        // member message, so a rebuild from any pick is observable.
        let listId = "announce.lists.example.com"
        let listHash = calculateListConversationHash(fromNormalizedListId: listId)
        let inbox = LabelBuilder().inbox().build(in: context)

        let listConversation = ConversationBuilder()
            .withParticipantHash(listHash)
            .withListId(listId)
            .asList()
            .withLastMessageDate(Date(timeIntervalSince1970: 100))
            .visible()
            .build(in: context)
        addConversationParticipant(email: Self.carol, to: listConversation)
        let homed = try addMessage(
            id: "msg-list-1", date: Date(timeIntervalSince1970: 100),
            from: Self.alice, to: [Self.me],
            labels: [inbox], in: listConversation
        )
        homed.listId = listId

        // A mis-homed list message moving in is what marks the list chat as
        // touched and exposes it to the row-rebuild pass.
        let lumped = ConversationBuilder()
            .withParticipantHash(Self.hashBob)
            .withLastMessageDate(Date(timeIntervalSince1970: 200))
            .visible()
            .build(in: context)
        try addMessage(
            id: "msg-b", date: Date(timeIntervalSince1970: 150),
            from: Self.bob, to: [Self.me],
            labels: [inbox], in: lumped
        )
        let misHomed = try addMessage(
            id: "msg-list-2", date: Date(timeIntervalSince1970: 200),
            from: Self.bob, to: [Self.me],
            labels: [inbox], in: lumped
        )
        misHomed.listId = listId
        try context.save()

        await runMigration()

        let states = try fetchConversationStates()
        let listState = try state(listHash, in: states)
        XCTAssertEqual(
            listState.messageIDs, ["msg-list-1", "msg-list-2"],
            "Fixture guard: the mis-homed list message must actually move in"
        )
        XCTAssertEqual(
            listState.participantEmails, [Self.carol],
            "Creation-seeded list rows must survive the row-rebuild pass"
        )
        XCTAssertEqual(listState.typeRaw, ConversationType.list.rawValue)
    }

    // MARK: - Fixture Helpers

    private func runMigration(
        aliases: Set<String> = [ParticipantSetSplitMigrationTests.me],
        flags: InMemoryMigrationFlagStore? = nil
    ) async {
        let service = DataCleanupService(
            coreDataStack: coreDataStack,
            conversationManager: ConversationManager(currentUserEmail: { Self.me }),
            migrationFlags: flags ?? migrationFlags,
            identityAliasProvider: { _ in aliases }
        )
        // A fresh background context per run mirrors the per-launch cleanup entry
        // point and keeps re-run tests honest about persisted state.
        let migrationContext = coreDataStack.newBackgroundContext()
        await service.splitConversationsByParticipantSetIfNeeded(in: migrationContext)
    }

    @discardableResult
    private func addMessage(
        id: String,
        date: Date,
        from: String,
        to: [String],
        cc: [String] = [],
        unread: Bool = false,
        labels: [Label] = [],
        threadId: String = "thread-lumped",
        in conversation: Conversation
    ) throws -> Message {
        let builder = MessageBuilder()
            .withId(id)
            .withThreadId(threadId)
            .withDate(date)
            .withSender(email: from)
            .inConversation(conversation)
        if unread {
            _ = builder.unread()
        }
        let message = builder.build(in: context)

        _ = try MessageParticipantFactory.create(from: from, kind: .from, for: message, in: context)
        for recipient in to {
            _ = try MessageParticipantFactory.create(from: recipient, kind: .to, for: message, in: context)
        }
        for recipient in cc {
            _ = try MessageParticipantFactory.create(from: recipient, kind: .cc, for: message, in: context)
        }
        for label in labels {
            message.addToLabels(label)
        }
        return message
    }

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

    // MARK: - State Assertions

    private struct ConversationState: Equatable {
        let id: UUID
        let participantHash: String?
        let listId: String?
        let archivedAt: Date?
        let hasInbox: Bool
        let inboxUnreadCount: Int32
        let lastMessageDate: Date?
        let messageIDs: Set<String>
        let participantEmails: Set<String>
        let typeRaw: String
        let pinned: Bool
    }

    /// Snapshots every conversation from a fresh context so assertions observe
    /// persisted store state, never stale objects registered with the fixture
    /// context (which does not auto-merge the migration's saves).
    private func fetchConversationStates() throws -> [ConversationState] {
        let fetchContext = stack.newBackgroundContext()
        return try fetchContext.performAndWait {
            let request = Conversation.fetchRequest()
            request.relationshipKeyPathsForPrefetching = [
                "messages", "participants", "participants.person"
            ]
            return try fetchContext.fetch(request).map { conversation in
                ConversationState(
                    id: conversation.id,
                    participantHash: conversation.participantHash,
                    listId: conversation.listId,
                    archivedAt: conversation.archivedAt,
                    hasInbox: conversation.hasInbox,
                    inboxUnreadCount: conversation.inboxUnreadCount,
                    lastMessageDate: conversation.lastMessageDate,
                    messageIDs: Set((conversation.messages ?? []).map(\.id)),
                    participantEmails: Set(
                        (conversation.participants ?? []).compactMap { $0.person?.email }
                    ),
                    typeRaw: conversation.type,
                    pinned: conversation.pinned
                )
            }
        }
    }

    private func state(
        _ participantHash: String,
        in states: [ConversationState],
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> ConversationState {
        try XCTUnwrap(
            states.first { $0.participantHash == participantHash },
            "No conversation found for participantHash \(participantHash.prefix(16))...",
            file: file,
            line: line
        )
    }
}
