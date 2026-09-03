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
    private static let relay = "legacy-relay@icloud.com"

    private static let hashAlice = calculateParticipantHash(from: [alice])
    private static let hashAliceBob = calculateParticipantHash(from: [alice, bob])
    private static let hashAliceBobCarol = calculateParticipantHash(from: [alice, bob, carol])
    private static let hashBob = calculateParticipantHash(from: [bob])

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

    func testAmbiguousMixedParticipantThreadIsPreserved() async throws {
        let inbox = LabelBuilder().inbox().build(in: context)
        let lumped = ConversationBuilder()
            .withParticipantHash(Self.hashAliceBobCarol)
            .withLastMessageDate(Date(timeIntervalSince1970: 300))
            .visible()
            .build(in: context)
        let lumpedID = lumped.id
        addConversationParticipant(email: Self.alice, to: lumped)
        addConversationParticipant(email: Self.bob, to: lumped)
        addConversationParticipant(email: Self.carol, to: lumped)

        // One legacy Gmail thread whose persisted message rows imply three
        // strict sets. With raw From unavailable, that shape is ambiguous with
        // truncated multi-From data and must remain anchored.
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
        XCTAssertEqual(states.count, 1)
        let preserved = try XCTUnwrap(states.first)
        XCTAssertEqual(preserved.id, lumpedID)
        XCTAssertEqual(preserved.participantHash, Self.hashAliceBobCarol)
        XCTAssertEqual(preserved.messageIDs, ["msg-a", "msg-ab", "msg-ac"])
        XCTAssertEqual(preserved.participantEmails, [Self.alice, Self.bob, Self.carol])
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

    func testRollupsAndUnreadCountsCorrectAfterHideMyEmailRepair() async throws {
        let inbox = LabelBuilder().inbox().build(in: context)
        let source = ConversationBuilder()
            .withParticipantHash("replaced-by-helper")
            .withUnreadCount(5)
            .withLastMessageDate(Date(timeIntervalSince1970: 100))
            .visible()
            .build(in: context)
        seedLegacyHideMyEmailIdentity([Self.alice], in: source)

        try addMessage(
            id: "msg-a-unread", date: Date(timeIntervalSince1970: 100),
            from: Self.alice, to: [Self.me], unread: true,
            labels: [inbox], in: source
        )
        try addMessage(
            id: "msg-a-old", date: Date(timeIntervalSince1970: 50),
            from: Self.alice, to: [Self.me], in: source
        )
        try context.save()

        await runMigration()

        let states = try fetchConversationStates()
        XCTAssertEqual(states.count, 1)

        let aliceState = try state(Self.hashAlice, in: states)
        XCTAssertTrue(aliceState.hasInbox)
        XCTAssertEqual(aliceState.inboxUnreadCount, 1)
        XCTAssertEqual(aliceState.lastMessageDate, Date(timeIntervalSince1970: 100))
        XCTAssertNil(aliceState.archivedAt)
        XCTAssertEqual(aliceState.messageIDs, ["msg-a-old", "msg-a-unread"])
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

    func testArchivedOutgoingSourceCreatesArchivedReplacement() async throws {
        let sent = LabelBuilder().sent().build(in: context)
        let archivedDate = Date(timeIntervalSince1970: 400)
        let source = ConversationBuilder()
            .withParticipantHash("replaced-by-helper")
            .withCreatedAt(Date(timeIntervalSince1970: 100))
            .withLastMessageDate(Date(timeIntervalSince1970: 300))
            .archivedOn(archivedDate)
            .setHidden()
            .build(in: context)
        seedLegacyHideMyEmailIdentity([Self.alice], in: source)
        let sourceID = source.id
        let message = try addMessage(
            id: "msg-archived-outgoing",
            date: Date(timeIntervalSince1970: 300),
            from: Self.me,
            to: [Self.alice],
            labels: [sent],
            in: source
        )
        message.isFromMe = true
        try context.save()

        await runMigration()

        let states = try fetchConversationStates()
        XCTAssertNil(states.first { $0.id == sourceID })
        let replacement = try state(Self.hashAlice, in: states)
        XCTAssertEqual(replacement.messageIDs, ["msg-archived-outgoing"])
        XCTAssertEqual(
            replacement.archivedAt,
            archivedDate,
            "A sent-only rollup must preserve the archived state inherited from its source"
        )
        XCTAssertTrue(replacement.hidden)
    }

    func testHideMyEmailRepairFoldsIntoMostRecentEpochNotNewOne() async throws {
        let inbox = LabelBuilder().inbox().build(in: context)
        let wrongHome = ConversationBuilder()
            .withParticipantHash("replaced-by-helper")
            .withLastMessageDate(Date(timeIntervalSince1970: 100))
            .visible()
            .build(in: context)
        seedLegacyHideMyEmailIdentity([Self.alice], in: wrongHome)
        let existingAliceChat = ConversationBuilder()
            .withParticipantHash(Self.hashAlice)
            .withLastMessageDate(Date(timeIntervalSince1970: 150))
            .visible()
            .build(in: context)
        let existingAliceID = existingAliceChat.id

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
            states.count, 1,
            "The mis-homed message must fold into the existing {alice} conversation, not a new one"
        )

        let aliceState = try state(Self.hashAlice, in: states)
        XCTAssertEqual(aliceState.id, existingAliceID)
        XCTAssertEqual(aliceState.messageIDs, ["msg-a-existing", "msg-mis-homed-a"])
    }

    func testMigrationIsIdempotentAcrossReRun() async throws {
        let inbox = LabelBuilder().inbox().build(in: context)
        let source = ConversationBuilder()
            .withParticipantHash("replaced-by-helper")
            .withLastMessageDate(Date(timeIntervalSince1970: 100))
            .visible()
            .build(in: context)
        seedLegacyHideMyEmailIdentity([Self.alice], in: source)

        try addMessage(
            id: "msg-a", date: Date(timeIntervalSince1970: 100),
            from: Self.alice, to: [Self.me],
            labels: [inbox], in: source
        )
        try context.save()

        await runMigration()
        let firstPass = try fetchConversationStates()
            .sorted { $0.id.uuidString < $1.id.uuidString }
        XCTAssertEqual(firstPass.count, 1)

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

    func testV1FlagDoesNotBlockHideMyEmailRecipientRepair() async throws {
        migrationFlags.set(true, forKey: "hasDoneParticipantSetSplitV1")

        let relay = "relay@icloud.com"
        let staleHash = calculateParticipantHash(from: [Self.alice, relay])
        let staleConversation = ConversationBuilder()
            .withParticipantHash(staleHash)
            .withLastMessageDate(Date(timeIntervalSince1970: 100))
            .visible()
            .build(in: context)
        addConversationParticipant(email: Self.alice, to: staleConversation)
        addConversationParticipant(
            email: relay,
            displayName: "Hide My Email",
            to: staleConversation
        )
        let staleConversationID = staleConversation.id
        try addMessage(
            id: "msg-hme-cc", date: Date(timeIntervalSince1970: 100),
            from: Self.alice, to: [Self.me],
            cc: ["Hide My Email <\(relay)>"], in: staleConversation
        )
        try context.save()

        await runMigration()

        XCTAssertTrue(migrationFlags.bool(forKey: DataCleanupService.participantSetSplitMigrationKey))
        let states = try fetchConversationStates()
        XCTAssertNil(states.first { $0.id == staleConversationID })
        XCTAssertEqual(try state(Self.hashAlice, in: states).messageIDs, ["msg-hme-cc"])
    }

    func testMaintenanceDoesNotReintroduceHideMyEmailAfterSplitMigration() async throws {
        let relay = "relay@icloud.com"
        let conversation = ConversationBuilder()
            .withParticipantHash(Self.hashAlice)
            .withLastMessageDate(Date(timeIntervalSince1970: 100))
            .visible()
            .build(in: context)
        addConversationParticipant(email: Self.alice, to: conversation)
        addConversationParticipant(
            email: relay,
            displayName: "Hide My Email",
            to: conversation
        )
        try addMessage(
            id: "msg-hme-cc", date: Date(timeIntervalSince1970: 100),
            from: Self.alice, to: [Self.me],
            cc: ["Hide My Email <\(relay)>"], in: conversation
        )
        try context.save()

        // Even though the message is already correctly homed, the split pass
        // scans it as a participant-row repair candidate. Maintenance must then
        // preserve that strict identity rather than reintroducing the relay.
        await runMigration()
        let postMigration = try state(Self.hashAlice, in: fetchConversationStates())
        XCTAssertEqual(postMigration.participantEmails, [Self.alice])

        let service = DataCleanupService(
            coreDataStack: coreDataStack,
            conversationManager: ConversationManager(currentUserEmail: { Self.me }),
            migrationFlags: migrationFlags,
            identityAliasProvider: { _ in [Self.me] }
        )
        await service.fixAndMergeIncorrectParticipantHashes(
            in: coreDataStack.newBackgroundContext()
        )

        let states = try fetchConversationStates()
        XCTAssertEqual(states.count, 1)
        XCTAssertEqual(states.first?.participantHash, Self.hashAlice)
        XCTAssertEqual(
            states.first?.participantEmails, [Self.alice],
            "Maintenance must remove the excluded relay row that replies consume"
        )
    }

    func testMaintenanceRemovesRelayWhenLegacyConversationWinsMerge() async throws {
        let relay = "relay@icloud.com"
        let canonical = ConversationBuilder()
            .withParticipantHash(Self.hashAlice)
            .withLastMessageDate(Date(timeIntervalSince1970: 100))
            .visible()
            .build(in: context)
        addConversationParticipant(email: Self.alice, to: canonical)
        _ = MessageBuilder()
            .withId("msg-canonical")
            .withDate(Date(timeIntervalSince1970: 100))
            .inConversation(canonical)
            .build(in: context)

        let legacy = ConversationBuilder()
            .withParticipantHash(calculateParticipantHash(from: [Self.alice, relay]))
            .withLastMessageDate(Date(timeIntervalSince1970: 300))
            .visible()
            .build(in: context)
        legacy.conversationType = .group
        let legacyID = legacy.id
        addConversationParticipant(email: Self.alice, to: legacy)
        addConversationParticipant(email: relay, displayName: "Hide My Email", to: legacy)
        for index in 0..<2 {
            _ = MessageBuilder()
                .withId("msg-legacy-\(index)")
                .withDate(Date(timeIntervalSince1970: TimeInterval(200 + index)))
                .inConversation(legacy)
                .build(in: context)
        }
        try context.save()

        let service = DataCleanupService(
            coreDataStack: coreDataStack,
            conversationManager: ConversationManager(currentUserEmail: { Self.me }),
            migrationFlags: migrationFlags,
            identityAliasProvider: { _ in [Self.me] }
        )
        await service.fixAndMergeIncorrectParticipantHashes(
            in: coreDataStack.newBackgroundContext()
        )

        let states = try fetchConversationStates()
        XCTAssertEqual(states.count, 1)
        XCTAssertEqual(states.first?.id, legacyID, "The larger legacy row should win the merge")
        XCTAssertEqual(states.first?.participantHash, Self.hashAlice)
        XCTAssertEqual(states.first?.typeRaw, ConversationType.oneToOne.rawValue)
        XCTAssertEqual(states.first?.participantEmails, [Self.alice])
        XCTAssertEqual(
            states.first?.messageIDs,
            ["msg-canonical", "msg-legacy-0", "msg-legacy-1"]
        )
    }

    func testMaintenanceUsesSelfFallbackWhenHideMyEmailIsOnlyParticipant() async throws {
        let conversation = ConversationBuilder()
            .withParticipantHash(calculateParticipantHash(from: ["relay@icloud.com"]))
            .withLastMessageDate(Date(timeIntervalSince1970: 100))
            .visible()
            .build(in: context)
        addConversationParticipant(
            email: "relay@icloud.com",
            displayName: "Hide My Email",
            to: conversation
        )
        try context.save()

        let service = DataCleanupService(
            coreDataStack: coreDataStack,
            conversationManager: ConversationManager(currentUserEmail: { Self.me }),
            migrationFlags: migrationFlags,
            identityAliasProvider: { _ in [Self.me] }
        )
        await service.fixAndMergeIncorrectParticipantHashes(
            in: coreDataStack.newBackgroundContext()
        )

        let states = try fetchConversationStates()
        XCTAssertEqual(states.count, 1)
        XCTAssertEqual(states.first?.participantHash, calculateParticipantHash(from: [Self.me]))
        XCTAssertEqual(states.first?.participantEmails, [])
    }

    func testMaintenanceLeavesPendingSendConversationCompletelyUntouched() async throws {
        let relay = "relay@icloud.com"
        let staleHash = calculateParticipantHash(from: [relay])
        let conversation = ConversationBuilder()
            .withParticipantHash(staleHash)
            .withCreatedAt(Date(timeIntervalSince1970: 100))
            .withLastMessageDate(Date(timeIntervalSince1970: 100))
            .visible()
            .build(in: context)
        let conversationID = conversation.id
        addConversationParticipant(
            email: relay,
            displayName: "Hide My Email",
            to: conversation
        )

        let record = context.insertTestObject(OutboundSendMutationRecord.self)
        record.id = UUID().uuidString
        record.createdAt = Date()
        record.conversationId = conversationID
        try context.save()

        let service = DataCleanupService(
            coreDataStack: coreDataStack,
            conversationManager: ConversationManager(currentUserEmail: { Self.me }),
            migrationFlags: migrationFlags,
            identityAliasProvider: { _ in [Self.me] }
        )
        let maintenanceContext = coreDataStack.newBackgroundContext()
        await service.fixAndMergeIncorrectParticipantHashes(in: maintenanceContext)
        await service.removeEmptyConversations(in: maintenanceContext)

        let states = try fetchConversationStates()
        let protected = try XCTUnwrap(states.first { $0.id == conversationID })
        XCTAssertEqual(protected.participantHash, staleHash)
        XCTAssertEqual(protected.participantEmails, [relay])
    }

    func testMaintenancePreservesPinnedShellAfterRemovingFinalRelay() async throws {
        let relay = "relay@icloud.com"
        let conversation = ConversationBuilder()
            .withParticipantHash(calculateParticipantHash(from: [relay]))
            .withCreatedAt(Date(timeIntervalSince1970: 100))
            .withLastMessageDate(Date(timeIntervalSince1970: 100))
            .visible()
            .build(in: context)
        let conversationID = conversation.id
        conversation.pinned = true
        addConversationParticipant(
            email: relay,
            displayName: "Hide My Email",
            to: conversation
        )
        try context.save()

        let service = DataCleanupService(
            coreDataStack: coreDataStack,
            conversationManager: ConversationManager(currentUserEmail: { Self.me }),
            migrationFlags: migrationFlags,
            identityAliasProvider: { _ in [Self.me] }
        )
        let maintenanceContext = coreDataStack.newBackgroundContext()
        await service.fixAndMergeIncorrectParticipantHashes(in: maintenanceContext)
        await service.removeEmptyConversations(in: maintenanceContext)

        let states = try fetchConversationStates()
        let preserved = try XCTUnwrap(states.first { $0.id == conversationID })
        XCTAssertEqual(preserved.participantHash, calculateParticipantHash(from: [Self.me]))
        XCTAssertEqual(preserved.participantEmails, [])
        XCTAssertTrue(preserved.pinned)
        XCTAssertFalse(preserved.muted)
        XCTAssertNotNil(preserved.archivedAt)
        XCTAssertTrue(preserved.hidden)
        XCTAssertNil(preserved.lastMessageDate)
    }

    func testMaintenancePreservesMutedShellAfterRemovingFinalRelay() async throws {
        let relay = "relay@icloud.com"
        let conversation = ConversationBuilder()
            .withParticipantHash(calculateParticipantHash(from: [relay]))
            .withCreatedAt(Date(timeIntervalSince1970: 100))
            .withLastMessageDate(Date(timeIntervalSince1970: 100))
            .visible()
            .build(in: context)
        let conversationID = conversation.id
        conversation.muted = true
        addConversationParticipant(
            email: relay,
            displayName: "Hide My Email",
            to: conversation
        )
        try context.save()

        let service = DataCleanupService(
            coreDataStack: coreDataStack,
            conversationManager: ConversationManager(currentUserEmail: { Self.me }),
            migrationFlags: migrationFlags,
            identityAliasProvider: { _ in [Self.me] }
        )
        let maintenanceContext = coreDataStack.newBackgroundContext()
        await service.fixAndMergeIncorrectParticipantHashes(in: maintenanceContext)
        await service.removeEmptyConversations(in: maintenanceContext)

        let states = try fetchConversationStates()
        let preserved = try XCTUnwrap(states.first { $0.id == conversationID })
        XCTAssertEqual(preserved.participantHash, calculateParticipantHash(from: [Self.me]))
        XCTAssertEqual(preserved.participantEmails, [])
        XCTAssertFalse(preserved.pinned)
        XCTAssertTrue(preserved.muted)
        XCTAssertNotNil(preserved.archivedAt)
        XCTAssertTrue(preserved.hidden)
        XCTAssertNil(preserved.lastMessageDate)
    }

    func testEmptyConversationFallbackArchivesStatefulShellsAndDeletesOrdinaryEmpty() throws {
        let mutedShell = ConversationBuilder()
            .withParticipantHash("muted-empty-hash")
            .withLastMessageDate(Date(timeIntervalSince1970: 100))
            .visible()
            .build(in: context)
        let mutedShellID = mutedShell.id
        mutedShell.muted = true
        let pinnedShell = ConversationBuilder()
            .withParticipantHash("pinned-empty-hash")
            .withLastMessageDate(Date(timeIntervalSince1970: 200))
            .visible()
            .build(in: context)
        let pinnedShellID = pinnedShell.id
        pinnedShell.pinned = true
        let disposableEmpty = ConversationBuilder()
            .withParticipantHash("fallback-disposable-hash")
            .visible()
            .build(in: context)
        let disposableEmptyID = disposableEmpty.id
        let pendingEmpty = ConversationBuilder()
            .withParticipantHash("fallback-pending-empty-hash")
            .visible()
            .build(in: context)
        let pendingEmptyID = pendingEmpty.id
        let pendingRecord = context.insertTestObject(OutboundSendMutationRecord.self)
        pendingRecord.id = UUID().uuidString
        pendingRecord.createdAt = Date()
        pendingRecord.conversationId = pendingEmptyID
        try context.save()

        let service = DataCleanupService(
            coreDataStack: coreDataStack,
            conversationManager: ConversationManager(currentUserEmail: { Self.me }),
            migrationFlags: migrationFlags,
            identityAliasProvider: { _ in [Self.me] }
        )
        service.removeEmptyConversationsFallback(in: context)

        let states = try fetchConversationStates()
        let preserved = try XCTUnwrap(states.first { $0.id == mutedShellID })
        XCTAssertFalse(preserved.pinned)
        XCTAssertTrue(preserved.muted)
        XCTAssertNotNil(preserved.archivedAt)
        XCTAssertTrue(preserved.hidden)
        XCTAssertNil(preserved.lastMessageDate)

        let pinned = try XCTUnwrap(states.first { $0.id == pinnedShellID })
        XCTAssertTrue(pinned.pinned)
        XCTAssertFalse(pinned.muted)
        XCTAssertNotNil(pinned.archivedAt)
        XCTAssertTrue(pinned.hidden)
        XCTAssertNil(pinned.lastMessageDate)
        XCTAssertNil(states.first { $0.id == disposableEmptyID })

        let pending = try XCTUnwrap(states.first { $0.id == pendingEmptyID })
        XCTAssertNil(pending.archivedAt)
        XCTAssertFalse(pending.hidden)
        XCTAssertEqual(
            try context.fetch(OutboundSendMutationRecord.fetchRequest()).compactMap(\.conversationId),
            [pendingEmptyID]
        )
    }

    func testEmptyConversationBatchArchivesStatefulShellAndDeletesOrdinaryEmpty() async throws {
        let sqliteStack = TestCoreDataStack(storeKind: .sqlite)
        let sqliteCoreDataStack = CoreDataStack(
            persistentContainerForTesting: sqliteStack.persistentContainer
        )
        let fixtureContext = sqliteStack.viewContext

        let pinnedShell = ConversationBuilder()
            .withParticipantHash("batch-pinned-empty-hash")
            .withLastMessageDate(Date(timeIntervalSince1970: 200))
            .visible()
            .build(in: fixtureContext)
        pinnedShell.pinned = true
        let pinnedShellID = pinnedShell.id
        let disposableEmpty = ConversationBuilder()
            .withParticipantHash("batch-disposable-empty-hash")
            .visible()
            .build(in: fixtureContext)
        let disposableEmptyID = disposableEmpty.id
        let pendingEmpty = ConversationBuilder()
            .withParticipantHash("batch-pending-empty-hash")
            .visible()
            .build(in: fixtureContext)
        let pendingEmptyID = pendingEmpty.id
        let pendingRecord = fixtureContext.insertTestObject(OutboundSendMutationRecord.self)
        pendingRecord.id = UUID().uuidString
        pendingRecord.createdAt = Date()
        pendingRecord.conversationId = pendingEmptyID
        try sqliteStack.saveViewContext()

        let service = DataCleanupService(
            coreDataStack: sqliteCoreDataStack,
            conversationManager: ConversationManager(currentUserEmail: { Self.me }),
            migrationFlags: InMemoryMigrationFlagStore(),
            identityAliasProvider: { _ in [Self.me] }
        )
        await service.removeEmptyConversations(
            in: sqliteCoreDataStack.newBackgroundContext()
        )

        let assertionContext = sqliteStack.newBackgroundContext()
        let durableState = try await assertionContext.perform {
            let conversations = try assertionContext.fetch(Conversation.fetchRequest())
            let pendingConversationIDs = try assertionContext
                .fetch(OutboundSendMutationRecord.fetchRequest())
                .compactMap(\.conversationId)
            return (conversations, pendingConversationIDs)
        }
        let conversations = durableState.0
        let preserved = try XCTUnwrap(
            conversations.first { $0.id == pinnedShellID }
        )
        XCTAssertTrue(preserved.pinned)
        XCTAssertNotNil(preserved.archivedAt)
        XCTAssertTrue(preserved.hidden)
        XCTAssertNil(preserved.lastMessageDate)
        XCTAssertNil(conversations.first { $0.id == disposableEmptyID })

        let pending = try XCTUnwrap(
            conversations.first { $0.id == pendingEmptyID }
        )
        XCTAssertNil(pending.archivedAt)
        XCTAssertFalse(pending.hidden)
        XCTAssertEqual(durableState.1, [pendingEmptyID])
    }

    func testEmptyAliasProviderDoesNotBurnFlag() async throws {
        let inbox = LabelBuilder().inbox().build(in: context)
        let source = ConversationBuilder()
            .withParticipantHash("replaced-by-helper")
            .withLastMessageDate(Date(timeIntervalSince1970: 100))
            .visible()
            .build(in: context)
        seedLegacyHideMyEmailIdentity([Self.alice], in: source)
        try addMessage(
            id: "msg-a", date: Date(timeIntervalSince1970: 100),
            from: Self.alice, to: [Self.me],
            labels: [inbox], in: source
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
        XCTAssertEqual(untouched.first?.messageIDs, ["msg-a"])

        // Once aliases resolve, the same flag store must still allow the split.
        await runMigration()

        XCTAssertTrue(migrationFlags.bool(forKey: DataCleanupService.participantSetSplitMigrationKey))
        let repaired = try fetchConversationStates()
        XCTAssertEqual(repaired.count, 1)
        XCTAssertEqual(try state(Self.hashAlice, in: repaired).messageIDs, ["msg-a"])
    }

    func testFailedRehomeSaveDoesNotBurnFlag() async throws {
        let source = ConversationBuilder()
            .withParticipantHash("replaced-by-helper")
            .withLastMessageDate(Date(timeIntervalSince1970: 100))
            .visible()
            .build(in: context)
        seedLegacyHideMyEmailIdentity([Self.alice], in: source)
        try addMessage(
            id: "msg-rehome-save-failure",
            date: Date(timeIntervalSince1970: 100),
            from: Self.alice,
            to: [Self.me],
            in: source
        )
        try context.save()

        let migrationContext = makeFailingMigrationContext(failingFromAttempt: 1)
        await runMigration(in: migrationContext)

        XCTAssertEqual(migrationContext.saveAttempts, 1)
        XCTAssertFalse(
            migrationFlags.bool(forKey: DataCleanupService.participantSetSplitMigrationKey),
            "A rolled-back re-home save must leave the migration eligible to retry"
        )
    }

    func testFailedEmptiedShellSaveDoesNotBurnFlag() async throws {
        let source = ConversationBuilder()
            .withParticipantHash("replaced-by-helper")
            .withCreatedAt(Date(timeIntervalSince1970: 100))
            .withLastMessageDate(Date(timeIntervalSince1970: 100))
            .visible()
            .build(in: context)
        seedLegacyHideMyEmailIdentity([Self.alice], in: source)
        let sourceID = source.id
        try addMessage(
            id: "msg-delete-save-failure",
            date: Date(timeIntervalSince1970: 100),
            from: Self.alice,
            to: [Self.me],
            in: source
        )
        try context.save()

        let migrationContext = makeFailingMigrationContext(failingFromAttempt: 2)
        await runMigration(in: migrationContext)

        XCTAssertEqual(migrationContext.saveAttempts, 2)
        XCTAssertFalse(
            migrationFlags.bool(forKey: DataCleanupService.participantSetSplitMigrationKey),
            "A rolled-back shell deletion must leave the migration eligible to retry"
        )
        let assertionContext = coreDataStack.newBackgroundContext()
        let sourceSurvived = try await assertionContext.perform {
            let request = Conversation.fetchRequest()
            request.predicate = NSPredicate(format: "id == %@", sourceID as CVarArg)
            return try assertionContext.count(for: request) == 1
        }
        XCTAssertTrue(sourceSurvived, "An unsaved shell deletion must not be published as durable")
    }

    func testFailedDuplicateMergeSaveDoesNotBurnFlag() async throws {
        for (index, date) in [100.0, 200.0].enumerated() {
            let conversation = ConversationBuilder()
                .withParticipantHash(Self.hashAlice)
                .withLastMessageDate(Date(timeIntervalSince1970: date))
                .visible()
                .build(in: context)
            try addMessage(
                id: "msg-duplicate-save-failure-\(index)",
                date: Date(timeIntervalSince1970: date),
                from: Self.alice,
                to: [Self.me],
                in: conversation
            )
        }
        try context.save()

        let migrationContext = makeFailingMigrationContext(failingFromAttempt: 1)
        await runMigration(in: migrationContext)

        XCTAssertEqual(migrationContext.saveAttempts, 1)
        XCTAssertFalse(
            migrationFlags.bool(forKey: DataCleanupService.participantSetSplitMigrationKey),
            "A rolled-back duplicate merge must leave the migration eligible to retry"
        )
    }

    func testFailedParticipantRowRebuildSaveDoesNotBurnFlag() async throws {
        let listId = "rebuild.lists.example.com"
        let source = ConversationBuilder()
            .withParticipantHash(Self.hashAliceBob)
            .withLastMessageDate(Date(timeIntervalSince1970: 200))
            .visible()
            .build(in: context)
        let sourceID = source.id
        addConversationParticipant(email: Self.alice, to: source)
        addConversationParticipant(email: Self.bob, to: source)
        addConversationParticipant(email: Self.carol, to: source)
        try addMessage(
            id: "msg-rebuild-keeper",
            date: Date(timeIntervalSince1970: 200),
            from: Self.alice,
            to: [Self.me, Self.bob],
            in: source
        )
        let mover = try addMessage(
            id: "msg-rebuild-mover",
            date: Date(timeIntervalSince1970: 100),
            from: Self.alice,
            to: [Self.me],
            in: source
        )
        mover.listId = listId
        try context.save()

        let migrationContext = makeFailingMigrationContext(failingFromAttempt: 2)
        await runMigration(in: migrationContext)

        XCTAssertEqual(migrationContext.saveAttempts, 2)
        XCTAssertFalse(
            migrationFlags.bool(forKey: DataCleanupService.participantSetSplitMigrationKey),
            "A rolled-back participant-row rebuild must leave the migration eligible to retry"
        )

        await runMigration()

        let states = try fetchConversationStates()
        let repairedSource = try XCTUnwrap(states.first { $0.id == sourceID })
        XCTAssertEqual(repairedSource.messageIDs, ["msg-rebuild-keeper"])
        XCTAssertEqual(
            repairedSource.participantEmails,
            [Self.alice, Self.bob],
            "A retry must rebuild stale rows even after Phase 1 already persisted its moves"
        )
        XCTAssertTrue(
            migrationFlags.bool(forKey: DataCleanupService.participantSetSplitMigrationKey),
            "The flag may be set only after the retry durably repairs participant rows"
        )
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

    func testLegacyMultiFromTruncationDoesNotDestructivelyNarrowConversation() async throws {
        let source = ConversationBuilder()
            .withParticipantHash(Self.hashAliceBob)
            .withLastMessageDate(Date(timeIntervalSince1970: 100))
            .visible()
            .build(in: context)
        let sourceID = source.id
        source.pinned = true
        source.muted = true
        addConversationParticipant(email: Self.alice, to: source)
        addConversationParticipant(email: Self.bob, to: source)
        try addMessage(
            id: "msg-legacy-multi-from",
            date: Date(timeIntervalSince1970: 100),
            from: Self.alice,
            to: [Self.me],
            in: source
        )
        try context.save()

        await runMigration()

        let states = try fetchConversationStates()
        XCTAssertEqual(states.count, 1)
        let preserved = try XCTUnwrap(states.first { $0.id == sourceID })
        XCTAssertEqual(preserved.participantHash, Self.hashAliceBob)
        XCTAssertEqual(preserved.participantEmails, [Self.alice, Self.bob])
        XCTAssertEqual(preserved.messageIDs, ["msg-legacy-multi-from"])
        XCTAssertTrue(preserved.pinned)
        XCTAssertTrue(preserved.muted)
        XCTAssertTrue(
            migrationFlags.bool(forKey: DataCleanupService.participantSetSplitMigrationKey)
        )
    }

    func testPendingSendDefersMigrationWithoutMutatingItsAnchor() async throws {
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
        protectedShell.pinned = true
        protectedShell.muted = true

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
            "A conversation referenced by a pending send record must survive unchanged"
        )
        XCTAssertEqual(protectedState.messageIDs, ["msg-protected-move"])
        XCTAssertTrue(protectedState.pinned)
        XCTAssertTrue(protectedState.muted)
        let unprotectedState = try XCTUnwrap(
            states.first { $0.id == unprotectedID }
        )
        XCTAssertEqual(unprotectedState.messageIDs, ["msg-unprotected-move"])
        XCTAssertFalse(
            migrationFlags.bool(forKey: DataCleanupService.participantSetSplitMigrationKey),
            "The deferred migration must retry after the pending send resolves"
        )
    }

    func testRetainedFailedSendDoesNotBlockUnrelatedMigrationWork() async throws {
        let protected = ConversationBuilder()
            .withParticipantHash(Self.hashAlice)
            .withLastMessageDate(Date(timeIntervalSince1970: 100))
            .visible()
            .build(in: context)
        let protectedID = protected.id
        addConversationParticipant(email: Self.alice, to: protected)
        try addMessage(
            id: "msg-retained-failure",
            date: Date(timeIntervalSince1970: 100),
            from: Self.alice,
            to: [Self.me],
            in: protected
        )

        let stale = ConversationBuilder()
            .withParticipantHash("replaced-by-helper")
            .withCreatedAt(Date(timeIntervalSince1970: 100))
            .withLastMessageDate(Date(timeIntervalSince1970: 200))
            .visible()
            .build(in: context)
        seedLegacyHideMyEmailIdentity([Self.bob], in: stale)
        let staleID = stale.id
        try addMessage(
            id: "msg-unrelated-repair",
            date: Date(timeIntervalSince1970: 200),
            from: Self.bob,
            to: [Self.me],
            in: stale
        )

        let record = context.insertTestObject(OutboundSendMutationRecord.self)
        record.id = UUID().uuidString
        record.createdAt = Date()
        record.conversationId = protectedID
        record.remoteCommittedMessageId = OutboundSendRemoteState.notSentMessageID
        try context.save()

        await runMigration()

        let states = try fetchConversationStates()
        XCTAssertEqual(
            states.first { $0.id == protectedID }?.messageIDs,
            ["msg-retained-failure"]
        )
        XCTAssertNil(states.first { $0.id == staleID })
        XCTAssertEqual(try state(Self.hashBob, in: states).messageIDs, ["msg-unrelated-repair"])
        XCTAssertTrue(
            migrationFlags.bool(forKey: DataCleanupService.participantSetSplitMigrationKey),
            "A retained terminal failure must not starve unrelated mailbox repair"
        )
    }

    func testProtectedMatchingDestinationDefersInsteadOfCreatingParallelConversation() async throws {
        let destination = ConversationBuilder()
            .withParticipantHash(Self.hashAlice)
            .withCreatedAt(Date(timeIntervalSince1970: 50))
            .withLastMessageDate(Date(timeIntervalSince1970: 100))
            .visible()
            .build(in: context)
        let destinationID = destination.id
        addConversationParticipant(email: Self.alice, to: destination)
        try addMessage(
            id: "msg-protected-destination",
            date: Date(timeIntervalSince1970: 100),
            from: Self.alice,
            to: [Self.me],
            in: destination
        )

        let archivedFallbackDate = Date(timeIntervalSince1970: 50)
        let archivedFallback = ConversationBuilder()
            .withParticipantHash(Self.hashAlice)
            .withCreatedAt(Date(timeIntervalSince1970: 25))
            .withLastMessageDate(archivedFallbackDate)
            .archivedOn(archivedFallbackDate)
            .build(in: context)
        let archivedFallbackID = archivedFallback.id
        addConversationParticipant(email: Self.alice, to: archivedFallback)
        try addMessage(
            id: "msg-archived-fallback",
            date: archivedFallbackDate,
            from: Self.alice,
            to: [Self.me],
            in: archivedFallback
        )

        let source = ConversationBuilder()
            .withParticipantHash("replaced-by-helper")
            .withCreatedAt(Date(timeIntervalSince1970: 50))
            .withLastMessageDate(Date(timeIntervalSince1970: 200))
            .visible()
            .build(in: context)
        seedLegacyHideMyEmailIdentity([Self.alice], in: source)
        let sourceID = source.id
        source.pinned = true
        source.muted = true
        try addMessage(
            id: "msg-awaiting-protected-destination",
            date: Date(timeIntervalSince1970: 200),
            from: Self.alice,
            to: [Self.me],
            in: source
        )

        let record = context.insertTestObject(OutboundSendMutationRecord.self)
        record.id = UUID().uuidString
        record.createdAt = Date()
        record.conversationId = destinationID
        record.remoteCommittedMessageId = OutboundSendRemoteState.notSentMessageID
        try context.save()

        await runMigration()

        var states = try fetchConversationStates()
        XCTAssertEqual(states.count, 3, "The protected destination must not revive an older epoch")
        XCTAssertEqual(states.first { $0.id == destinationID }?.messageIDs, ["msg-protected-destination"])
        XCTAssertEqual(states.first { $0.id == sourceID }?.messageIDs, ["msg-awaiting-protected-destination"])
        XCTAssertEqual(states.first { $0.id == archivedFallbackID }?.archivedAt, archivedFallbackDate)
        XCTAssertFalse(
            migrationFlags.bool(forKey: DataCleanupService.participantSetSplitMigrationKey),
            "The migration must retry after the destination's send record clears"
        )

        context.delete(record)
        try context.save()
        await runMigration()

        states = try fetchConversationStates()
        XCTAssertEqual(states.count, 2)
        XCTAssertNil(states.first { $0.id == sourceID })
        let repaired = try XCTUnwrap(states.first { $0.id == destinationID })
        XCTAssertEqual(
            repaired.messageIDs,
            ["msg-awaiting-protected-destination", "msg-protected-destination"]
        )
        XCTAssertTrue(repaired.pinned)
        XCTAssertTrue(repaired.muted)
        XCTAssertEqual(states.first { $0.id == archivedFallbackID }?.archivedAt, archivedFallbackDate)
        XCTAssertTrue(
            migrationFlags.bool(forKey: DataCleanupService.participantSetSplitMigrationKey)
        )
    }

    func testProtectedCorrectHashWithStaleRowsDefersUntilRecordClears() async throws {
        let protected = ConversationBuilder()
            .withParticipantHash(Self.hashAlice)
            .withLastMessageDate(Date(timeIntervalSince1970: 100))
            .visible()
            .build(in: context)
        let protectedID = protected.id
        addConversationParticipant(email: Self.alice, to: protected)
        addConversationParticipant(email: Self.carol, to: protected)
        try addMessage(
            id: "msg-protected-stale-rows",
            date: Date(timeIntervalSince1970: 100),
            from: Self.alice,
            to: [Self.me],
            in: protected
        )

        let record = context.insertTestObject(OutboundSendMutationRecord.self)
        record.id = UUID().uuidString
        record.createdAt = Date()
        record.conversationId = protectedID
        record.remoteCommittedMessageId = OutboundSendRemoteState.notSentMessageID
        try context.save()

        await runMigration()

        var protectedState = try XCTUnwrap(
            fetchConversationStates().first { $0.id == protectedID }
        )
        XCTAssertEqual(protectedState.participantEmails, [Self.alice, Self.carol])
        XCTAssertFalse(
            migrationFlags.bool(forKey: DataCleanupService.participantSetSplitMigrationKey),
            "A protected addressing repair must remain eligible to retry"
        )

        context.delete(record)
        try context.save()
        await runMigration()

        protectedState = try XCTUnwrap(
            fetchConversationStates().first { $0.id == protectedID }
        )
        XCTAssertEqual(protectedState.participantEmails, [Self.alice])
        XCTAssertTrue(
            migrationFlags.bool(forKey: DataCleanupService.participantSetSplitMigrationKey)
        )
    }

    func testRecentSourceDrainedByMigrationTransfersStateAndIsDeleted() async throws {
        let source = ConversationBuilder()
            .withParticipantHash("replaced-by-helper")
            .withCreatedAt(Date())
            .withLastMessageDate(Date(timeIntervalSince1970: 100))
            .visible()
            .build(in: context)
        seedLegacyHideMyEmailIdentity([Self.alice], in: source)
        let sourceID = source.id
        source.pinned = true
        source.muted = true
        try addMessage(
            id: "msg-recent-move", date: Date(timeIntervalSince1970: 100),
            from: Self.alice, to: [Self.me], in: source
        )
        try context.save()

        await runMigration()

        let states = try fetchConversationStates()
        XCTAssertNil(
            states.first { $0.id == sourceID },
            "Creation grace must not retain a shell this run demonstrably drained"
        )

        let destination = try state(Self.hashAlice, in: states)
        XCTAssertEqual(destination.messageIDs, ["msg-recent-move"])
        XCTAssertTrue(destination.pinned)
        XCTAssertTrue(destination.muted)
        XCTAssertTrue(
            migrationFlags.bool(forKey: DataCleanupService.participantSetSplitMigrationKey)
        )
    }

    func testParticipantRowsRebuiltToMatchMessages() async throws {
        let listId = "rows.lists.example.com"
        let inbox = LabelBuilder().inbox().build(in: context)
        let lumped = ConversationBuilder()
            .withParticipantHash(Self.hashAliceBob)
            .withLastMessageDate(Date(timeIntervalSince1970: 200))
            .visible()
            .build(in: context)
        let lumpedID = lumped.id

        // Participant rows carry a stale HME relay excluded by strict identity.
        addConversationParticipant(email: Self.alice, to: lumped)
        addConversationParticipant(email: Self.bob, to: lumped)
        addConversationParticipant(
            email: Self.relay,
            displayName: "Hide My Email",
            to: lumped
        )

        try addMessage(
            id: "msg-ab-keeper", date: Date(timeIntervalSince1970: 200),
            from: Self.alice, to: [Self.me, Self.bob],
            labels: [inbox], in: lumped
        )
        // A list move makes the conversation touched without guessing about a
        // legacy normal participant omitted from message rows.
        let mover = try addMessage(
            id: "msg-a-mover", date: Date(timeIntervalSince1970: 100),
            from: Self.alice, to: [Self.me],
            labels: [inbox], in: lumped
        )
        mover.listId = listId
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
        XCTAssertEqual(
            try state(calculateListConversationHash(fromNormalizedListId: listId), in: states).messageIDs,
            ["msg-a-mover"]
        )
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

    func testDrainedSourceRetargetsPendingActionAndUnknownActionShellIsRetained() async throws {
        let source = ConversationBuilder()
            .withParticipantHash("replaced-by-helper")
            .withCreatedAt(Date(timeIntervalSince1970: 100))
            .withLastMessageDate(Date(timeIntervalSince1970: 100))
            .visible()
            .build(in: context)
        let sourceID = source.id
        seedLegacyHideMyEmailIdentity([Self.alice], in: source)
        try addMessage(
            id: "msg-action-source",
            date: Date(timeIntervalSince1970: 100),
            from: Self.alice,
            to: [Self.me],
            in: source
        )

        let unknownShell = ConversationBuilder()
            .withParticipantHash("stale-unknown-action-shell")
            .withCreatedAt(Date(timeIntervalSince1970: 50))
            .withLastMessageDate(Date(timeIntervalSince1970: 50))
            .visible()
            .build(in: context)
        let unknownShellID = unknownShell.id

        let payload = #"{"messageIds":["msg-action-source"]}"#
        let mappedAction = PendingActionBuilder()
            .withActionType(PendingAction.ActionType.archiveConversation.rawValue)
            .forConversation(sourceID)
            .withPayload(payload)
            .pending()
            .build(in: context)
        let mappedActionID = mappedAction.id
        let unknownAction = PendingActionBuilder()
            .withActionType(PendingAction.ActionType.archiveConversation.rawValue)
            .forConversation(unknownShellID)
            .withPayload(#"{"messageIds":["already-moved-message"]}"#)
            .pending()
            .build(in: context)
        let unknownActionID = unknownAction.id
        try context.save()

        await runMigration()

        let cleanupService = DataCleanupService(
            coreDataStack: coreDataStack,
            conversationManager: ConversationManager(currentUserEmail: { Self.me }),
            migrationFlags: migrationFlags,
            identityAliasProvider: { _ in [Self.me] }
        )
        await cleanupService.removeEmptyConversations(
            in: coreDataStack.newBackgroundContext()
        )
        await cleanupService.removeOrphanedPendingActions(
            in: coreDataStack.newBackgroundContext()
        )

        let verificationContext = stack.newBackgroundContext()
        let state = try await verificationContext.perform {
            let conversations = try verificationContext.fetch(Conversation.fetchRequest())
            let actions = try verificationContext.fetch(PendingAction.fetchRequest())
            let destinationID = conversations.first {
                $0.participantHash == Self.hashAlice
            }?.id
            let retainedUnknownShell = conversations.first { $0.id == unknownShellID }
            let durableMappedAction = actions.first { $0.id == mappedActionID }
            let durableUnknownAction = actions.first { $0.id == unknownActionID }
            return (
                sourceExists: conversations.contains { $0.id == sourceID },
                destinationID: destinationID,
                mappedActionConversationID: durableMappedAction?.conversationId,
                mappedActionPayload: durableMappedAction?.payload,
                unknownShellExists: retainedUnknownShell != nil,
                unknownShellIsEmpty: retainedUnknownShell?.messages?.isEmpty,
                unknownShellArchivedAt: retainedUnknownShell?.archivedAt,
                unknownShellIsHidden: retainedUnknownShell?.hidden,
                unknownActionConversationID: durableUnknownAction?.conversationId
            )
        }
        XCTAssertFalse(state.sourceExists)
        let destinationID = try XCTUnwrap(state.destinationID)
        XCTAssertEqual(state.mappedActionConversationID, destinationID)
        XCTAssertEqual(state.mappedActionPayload, payload)

        XCTAssertTrue(state.unknownShellExists)
        XCTAssertEqual(state.unknownShellIsEmpty, true)
        XCTAssertNotNil(state.unknownShellArchivedAt)
        XCTAssertEqual(state.unknownShellIsHidden, true)
        XCTAssertEqual(state.unknownActionConversationID, unknownShellID)
    }

    func testOrphanedPendingActionDetachesMetadataWithoutLosingCommand() async throws {
        let missingConversationID = UUID()
        let payload = #"{"messageIds":["still-actionable-message"]}"#
        let action = PendingActionBuilder()
            .withActionType(PendingAction.ActionType.archiveConversation.rawValue)
            .forConversation(missingConversationID)
            .withPayload(payload)
            .pending()
            .build(in: context)
        let actionID = action.id
        try context.save()

        let cleanupService = DataCleanupService(
            coreDataStack: coreDataStack,
            conversationManager: ConversationManager(currentUserEmail: { Self.me }),
            migrationFlags: migrationFlags,
            identityAliasProvider: { _ in [Self.me] }
        )
        await cleanupService.removeOrphanedPendingActions(
            in: coreDataStack.newBackgroundContext()
        )

        let verificationContext = stack.newBackgroundContext()
        let durableAction = try await verificationContext.perform {
            let request = PendingAction.fetchRequest()
            request.predicate = NSPredicate(format: "id == %@", actionID as CVarArg)
            let action = try XCTUnwrap(verificationContext.fetch(request).first)
            return (action.status, action.payload, action.conversationId)
        }
        XCTAssertEqual(durableAction.0, "pending")
        XCTAssertEqual(durableAction.1, payload)
        XCTAssertNil(durableAction.2)
    }

    func testStatefulProtectedCrashShapeIsRetainedWithoutDestinationMapping() async throws {
        // A prior pass drained this source while it was protected by the
        // creation grace or a pending send, then crashed before setting V2.
        // On retry there are no movers left, so no destination map can be
        // reconstructed; deleting the shell would silently lose user state.
        let strandedShell = ConversationBuilder()
            .withParticipantHash("stale-protected-hash")
            .withCreatedAt(Date(timeIntervalSince1970: 100))
            .withLastMessageDate(Date(timeIntervalSince1970: 100))
            .visible()
            .build(in: context)
        strandedShell.muted = true
        addConversationParticipant(email: Self.bob, to: strandedShell)
        let strandedID = strandedShell.id

        try context.save()

        await runMigration()

        let states = try fetchConversationStates()
        let preserved = try XCTUnwrap(states.first { $0.id == strandedID })
        XCTAssertTrue(preserved.messageIDs.isEmpty)
        XCTAssertFalse(preserved.pinned)
        XCTAssertTrue(preserved.muted)
        XCTAssertNotNil(preserved.archivedAt)
        XCTAssertTrue(preserved.hidden)
        XCTAssertNil(preserved.lastMessageDate)
        XCTAssertTrue(
            migrationFlags.bool(forKey: DataCleanupService.participantSetSplitMigrationKey)
        )
    }

    func testPinnedStateFollowsFullyDrainedShellToDestination() async throws {
        let inbox = LabelBuilder().inbox().build(in: context)
        // The user pinned this chat; its stored identity was wrong, so the
        // migration drains it entirely into the strict {alice} conversation.
        let pinnedShell = ConversationBuilder()
            .withParticipantHash("replaced-by-helper")
            .withCreatedAt(Date(timeIntervalSince1970: 100))
            .withLastMessageDate(Date(timeIntervalSince1970: 100))
            .visible()
            .build(in: context)
        seedLegacyHideMyEmailIdentity([Self.alice], in: pinnedShell)
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

    func testPinnedAndMutedStatePersistWithInterimRehomeSave() async throws {
        let existingDestination = ConversationBuilder()
            .withParticipantHash(Self.hashAlice)
            .withLastMessageDate(Date(timeIntervalSince1970: 1_000))
            .visible()
            .build(in: context)
        existingDestination.pinned = true
        try addMessage(
            id: "msg-existing-destination", date: Date(timeIntervalSince1970: 1_000),
            from: Self.alice, to: [Self.me], in: existingDestination
        )

        let source = ConversationBuilder()
            .withParticipantHash("replaced-by-helper")
            .withCreatedAt(Date(timeIntervalSince1970: 100))
            .withLastMessageDate(Date(timeIntervalSince1970: 500))
            .visible()
            .build(in: context)
        seedLegacyHideMyEmailIdentity([Self.alice], in: source)
        source.pinned = false
        source.muted = true

        // Exactly 500 moving rows sort before the destination's resident row,
        // so the first interim save persists the fully drained source before
        // Phase 2 can delete it. The destination must already carry the OR of
        // both conversations' user state at this crash boundary.
        for index in 0..<500 {
            try addMessage(
                id: "msg-state-\(index)",
                date: Date(timeIntervalSince1970: TimeInterval(index + 1)),
                from: Self.alice,
                to: [Self.me],
                in: source
            )
        }
        try context.save()

        let migrationContext = coreDataStack.newBackgroundContext()
        let sourceObjectID = source.objectID
        let probe = MigrationSaveStateProbe()
        let observer = NotificationCenter.default.addObserver(
            forName: .NSManagedObjectContextDidSave,
            object: migrationContext,
            queue: nil
        ) { notification in
            let inserted = notification.userInfo?[NSInsertedObjectsKey]
                as? Set<NSManagedObject> ?? []
            let updated = notification.userInfo?[NSUpdatedObjectsKey]
                as? Set<NSManagedObject> ?? []
            let savedConversations = inserted.union(updated)
                .compactMap { $0 as? Conversation }
            guard let destination = savedConversations.first(where: {
                $0.participantHash == Self.hashAlice
            }),
            let savedSource = savedConversations.first(where: {
                $0.objectID == sourceObjectID
            }) else {
                return
            }
            probe.capture(
                destinationPinned: destination.pinned,
                destinationMuted: destination.muted,
                sourcePinned: savedSource.pinned,
                sourceMuted: savedSource.muted
            )
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        await runMigration(in: migrationContext)

        XCTAssertEqual(
            probe.firstState,
            .init(
                destinationPinned: true,
                destinationMuted: true,
                sourcePinned: false,
                sourceMuted: false
            )
        )
        let destination = try state(Self.hashAlice, in: fetchConversationStates())
        XCTAssertTrue(destination.pinned)
        XCTAssertTrue(destination.muted)
    }

    func testDrainedSourceIsNotReusedAsLaterDestinationInSamePass() async throws {
        let listId = "drain.lists.example.com"
        let listHash = calculateListConversationHash(fromNormalizedListId: listId)
        let source = ConversationBuilder()
            .withParticipantHash(Self.hashBob)
            .withCreatedAt(Date(timeIntervalSince1970: 100))
            .withLastMessageDate(Date(timeIntervalSince1970: 100))
            .visible()
            .build(in: context)
        let sourceID = source.id
        source.pinned = true
        addConversationParticipant(email: Self.bob, to: source)
        let listMessage = try addMessage(
            id: "msg-list-drains-bob-shell", date: Date(timeIntervalSince1970: 100),
            from: Self.alice, to: [Self.me], in: source
        )
        listMessage.listId = listId

        let wrongHome = ConversationBuilder()
            .withParticipantHash("replaced-by-helper")
            .withCreatedAt(Date(timeIntervalSince1970: 100))
            .withLastMessageDate(Date(timeIntervalSince1970: 200))
            .visible()
            .build(in: context)
        seedLegacyHideMyEmailIdentity([Self.bob], in: wrongHome)
        try addMessage(
            id: "msg-b-after-drain", date: Date(timeIntervalSince1970: 200),
            from: Self.bob, to: [Self.me], in: wrongHome
        )
        try context.save()

        await runMigration()

        let states = try fetchConversationStates()
        XCTAssertNil(states.first { $0.id == sourceID })
        let listDestination = try state(listHash, in: states)
        XCTAssertTrue(listDestination.pinned)
        XCTAssertFalse(listDestination.muted)
        let bobDestination = try state(Self.hashBob, in: states)
        XCTAssertNotEqual(bobDestination.id, sourceID)
        XCTAssertFalse(bobDestination.pinned)
        XCTAssertFalse(bobDestination.muted)
    }

    func testRerunDoesNotDuplicateStateWhenDrainedShellBecomesDestination() async throws {
        // This is the persisted shape immediately after an interim save and
        // crash: Alice already received the old shell's state, while the empty
        // shell remains available under Bob's hash for the retry.
        let aliceDestination = ConversationBuilder()
            .withParticipantHash(Self.hashAlice)
            .withLastMessageDate(Date(timeIntervalSince1970: 100))
            .visible()
            .build(in: context)
        aliceDestination.pinned = true
        aliceDestination.muted = true
        try addMessage(
            id: "msg-a-after-crash", date: Date(timeIntervalSince1970: 100),
            from: Self.alice, to: [Self.me], in: aliceDestination
        )

        let drainedShell = ConversationBuilder()
            .withParticipantHash(Self.hashBob)
            .withCreatedAt(Date(timeIntervalSince1970: 100))
            .withLastMessageDate(Date(timeIntervalSince1970: 200))
            .visible()
            .build(in: context)
        let drainedShellID = drainedShell.id

        let wrongHome = ConversationBuilder()
            .withParticipantHash("replaced-by-helper")
            .withLastMessageDate(Date(timeIntervalSince1970: 300))
            .visible()
            .build(in: context)
        seedLegacyHideMyEmailIdentity([Self.bob], in: wrongHome)
        try addMessage(
            id: "msg-b-after-crash", date: Date(timeIntervalSince1970: 300),
            from: Self.bob, to: [Self.me], in: wrongHome
        )
        try context.save()

        await runMigration()

        let states = try fetchConversationStates()
        let bobDestination = try XCTUnwrap(states.first { $0.id == drainedShellID })
        XCTAssertEqual(bobDestination.messageIDs, ["msg-b-after-crash"])
        XCTAssertFalse(bobDestination.pinned)
        XCTAssertFalse(bobDestination.muted)
        let aliceState = try state(Self.hashAlice, in: states)
        XCTAssertTrue(aliceState.pinned)
        XCTAssertTrue(aliceState.muted)
    }

    func testPinnedAndMutedStateStayOnSourceWhenItRetainsAMessage() async throws {
        let listId = "state.lists.example.com"
        let listHash = calculateListConversationHash(fromNormalizedListId: listId)
        let source = ConversationBuilder()
            .withParticipantHash(Self.hashAlice)
            .withLastMessageDate(Date(timeIntervalSince1970: 200))
            .visible()
            .build(in: context)
        source.pinned = true
        source.muted = true
        addConversationParticipant(email: Self.alice, to: source)
        try addMessage(
            id: "msg-a-stays", date: Date(timeIntervalSince1970: 100),
            from: Self.alice, to: [Self.me], in: source
        )
        let mover = try addMessage(
            id: "msg-b-moves", date: Date(timeIntervalSince1970: 200),
            from: Self.bob, to: [Self.me], in: source
        )
        mover.listId = listId
        try context.save()

        await runMigration()

        let states = try fetchConversationStates()
        let aliceState = try state(Self.hashAlice, in: states)
        XCTAssertTrue(aliceState.pinned)
        XCTAssertTrue(aliceState.muted)
        let movedState = try state(listHash, in: states)
        XCTAssertFalse(movedState.pinned)
        XCTAssertFalse(movedState.muted)
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
        flags: InMemoryMigrationFlagStore? = nil,
        in migrationContext: NSManagedObjectContext? = nil
    ) async {
        let service = DataCleanupService(
            coreDataStack: coreDataStack,
            conversationManager: ConversationManager(currentUserEmail: { Self.me }),
            migrationFlags: flags ?? migrationFlags,
            identityAliasProvider: { _ in aliases }
        )
        // A fresh background context per run mirrors the per-launch cleanup entry
        // point and keeps re-run tests honest about persisted state.
        let targetContext = migrationContext ?? coreDataStack.newBackgroundContext()
        await service.splitConversationsByParticipantSetIfNeeded(in: targetContext)
    }

    private func makeFailingMigrationContext(
        failingFromAttempt: Int
    ) -> ScriptedSaveContext {
        let context = ScriptedSaveContext(
            error: NSError(domain: NSCocoaErrorDomain, code: NSManagedObjectMergeError),
            failingFromAttempt: failingFromAttempt
        )
        context.persistentStoreCoordinator = stack.persistentContainer.persistentStoreCoordinator
        context.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
        return context
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

    /// Seeds the source shape produced before Hide My Email recipients were
    /// excluded from conversation identity. The source hash and rows remain
    /// internally consistent, while filtering the relay yields `participants`.
    private func seedLegacyHideMyEmailIdentity(
        _ participants: [String],
        in conversation: Conversation
    ) {
        conversation.participantHash = calculateParticipantHash(
            from: participants + [Self.relay]
        )
        for email in participants {
            addConversationParticipant(email: email, to: conversation)
        }
        addConversationParticipant(
            email: Self.relay,
            displayName: "Hide My Email",
            to: conversation
        )
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
        let muted: Bool
        let hidden: Bool
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
                    pinned: conversation.pinned,
                    muted: conversation.muted,
                    hidden: conversation.hidden
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

    private final class MigrationSaveStateProbe: @unchecked Sendable {
        struct State: Equatable {
            let destinationPinned: Bool
            let destinationMuted: Bool
            let sourcePinned: Bool
            let sourceMuted: Bool
        }

        private let lock = NSLock()
        private var storedState: State?

        var firstState: State? {
            lock.lock()
            defer { lock.unlock() }
            return storedState
        }

        func capture(
            destinationPinned: Bool,
            destinationMuted: Bool,
            sourcePinned: Bool,
            sourceMuted: Bool
        ) {
            lock.lock()
            defer { lock.unlock() }
            if storedState == nil {
                storedState = State(
                    destinationPinned: destinationPinned,
                    destinationMuted: destinationMuted,
                    sourcePinned: sourcePinned,
                    sourceMuted: sourceMuted
                )
            }
        }
    }
}
