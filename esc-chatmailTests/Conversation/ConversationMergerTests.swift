import XCTest
import CoreData
@testable import esc_chatmail

/// Tests for ConversationMerger duplicate detection and merging logic.
final class ConversationMergerTests: XCTestCase {

    var testStack: TestCoreDataStack!
    var context: NSManagedObjectContext!
    var merger: ConversationMerger!

    override func setUp() {
        super.setUp()
        testStack = TestCoreDataStack()
        context = testStack.viewContext
        // Back the merger with the test container: the merger saves through
        // its stack and merges results into its stack's viewContext, so
        // handing it CoreDataStack.shared would route every merge through the
        // app's real store and main-queue context.
        merger = ConversationMerger(
            coreDataStack: CoreDataStack(persistentContainerForTesting: testStack.persistentContainer)
        )
    }

    override func tearDown() {
        context = nil
        testStack = nil
        merger = nil
        super.tearDown()
    }

    // MARK: - Winner Selection Tests

    func testSelectWinner_prefersConversationWithMoreMessages() throws {
        // Create conversation with 1 message
        let conv1 = ConversationBuilder()
            .withKeyHash("hash1")
            .withDisplayName("Conv 1")
            .build(in: context)

        let _ = MessageBuilder()
            .withId("msg1")
            .inConversation(conv1)
            .build(in: context)

        // Create conversation with 3 messages
        let conv2 = ConversationBuilder()
            .withKeyHash("hash2")
            .withDisplayName("Conv 2")
            .build(in: context)

        let _ = MessageBuilder().withId("msg2").inConversation(conv2).build(in: context)
        let _ = MessageBuilder().withId("msg3").inConversation(conv2).build(in: context)
        let _ = MessageBuilder().withId("msg4").inConversation(conv2).build(in: context)

        try testStack.saveViewContext()

        // Test winner selection
        let winner = merger.selectWinner(from: [conv1, conv2])

        XCTAssertNotNil(winner, "Should return a winner for non-empty group")
        XCTAssertEqual(winner?.displayName, "Conv 2", "Should select conversation with more messages")
    }

    func testSelectWinner_prefersMoreRecentWhenEqualMessageCount() throws {
        let oldDate = Calendar.current.date(byAdding: .day, value: -7, to: Date())!
        let newDate = Date()

        // Create older conversation
        let oldConv = ConversationBuilder()
            .withKeyHash("old")
            .withDisplayName("Old Conv")
            .withLastMessageDate(oldDate)
            .build(in: context)

        // Create newer conversation
        let newConv = ConversationBuilder()
            .withKeyHash("new")
            .withDisplayName("New Conv")
            .withLastMessageDate(newDate)
            .build(in: context)

        try testStack.saveViewContext()

        // Both have 0 messages, should prefer newer
        let winner = merger.selectWinner(from: [oldConv, newConv])

        XCTAssertNotNil(winner, "Should return a winner for non-empty group")
        XCTAssertEqual(winner?.displayName, "New Conv", "Should select more recent conversation")
    }

    func testSelectWinner_prefersVisibleConversationOverArchivedConversation() throws {
        let visibleConversation = ConversationBuilder()
            .withKeyHash("visible")
            .withDisplayName("Visible Conv")
            .withLastMessageDate(Date(timeIntervalSince1970: 1))
            .visible()
            .build(in: context)

        let archivedConversation = ConversationBuilder()
            .withKeyHash("archived")
            .withDisplayName("Archived Conv")
            .withLastMessageDate(Date(timeIntervalSince1970: 2))
            .archived()
            .setHidden()
            .build(in: context)

        let _ = MessageBuilder()
            .withId("visible-msg")
            .inConversation(visibleConversation)
            .build(in: context)

        let _ = MessageBuilder()
            .withId("archived-msg-1")
            .inConversation(archivedConversation)
            .build(in: context)

        let _ = MessageBuilder()
            .withId("archived-msg-2")
            .inConversation(archivedConversation)
            .build(in: context)

        try testStack.saveViewContext()

        let winner = merger.selectWinner(from: [visibleConversation, archivedConversation])

        XCTAssertEqual(winner?.objectID, visibleConversation.objectID)
    }

    // MARK: - Merge Logic Tests

    func testMerge_reassignsMessages() throws {
        let winner = ConversationBuilder()
            .withKeyHash("winner")
            .withDisplayName("Winner")
            .build(in: context)

        let loser = ConversationBuilder()
            .withKeyHash("loser")
            .withDisplayName("Loser")
            .build(in: context)

        // Add messages to loser
        let msg1 = MessageBuilder().withId("msg1").inConversation(loser).build(in: context)
        let msg2 = MessageBuilder().withId("msg2").inConversation(loser).build(in: context)

        try testStack.saveViewContext()

        XCTAssertEqual(loser.messages?.count, 2)
        XCTAssertEqual(winner.messages?.count ?? 0, 0)

        // Merge
        merger.merge(from: loser, into: winner)

        XCTAssertEqual(msg1.conversation, winner)
        XCTAssertEqual(msg2.conversation, winner)
    }

    func testMerge_preservesNewerLastMessageDate() throws {
        let oldDate = Calendar.current.date(byAdding: .day, value: -7, to: Date())!
        let newDate = Date()

        let winner = ConversationBuilder()
            .withKeyHash("winner")
            .withLastMessageDate(oldDate)
            .build(in: context)
        MessageBuilder()
            .withId("winner-old-message")
            .withDate(oldDate)
            .inConversation(winner)
            .build(in: context)

        let loser = ConversationBuilder()
            .withKeyHash("loser")
            .withLastMessageDate(newDate)
            .build(in: context)
        MessageBuilder()
            .withId("loser-new-message")
            .withDate(newDate)
            .inConversation(loser)
            .build(in: context)

        try testStack.saveViewContext()

        merger.merge(from: loser, into: winner)

        // Winner should now have the newer date
        XCTAssertEqual(winner.lastMessageDate, newDate)
    }

    func testMerge_preservesSnippetFromNewestConversation() throws {
        let oldDate = Date(timeIntervalSince1970: 100)
        let newDate = Date(timeIntervalSince1970: 200)

        let winner = ConversationBuilder()
            .withKeyHash("winner")
            .withSnippet("Old winner snippet")
            .withLastMessageDate(oldDate)
            .build(in: context)
        MessageBuilder()
            .withId("winner-old-snippet-message")
            .withDate(oldDate)
            .withSnippet("Old winner snippet")
            .inConversation(winner)
            .build(in: context)

        let loser = ConversationBuilder()
            .withKeyHash("loser")
            .withSnippet("New loser snippet")
            .withLastMessageDate(newDate)
            .build(in: context)
        MessageBuilder()
            .withId("loser-new-snippet-message")
            .withDate(newDate)
            .withSnippet("New loser snippet")
            .inConversation(loser)
            .build(in: context)

        try testStack.saveViewContext()

        merger.merge(from: loser, into: winner)

        XCTAssertEqual(winner.lastMessageDate, newDate)
        XCTAssertEqual(winner.snippet, "New loser snippet")
    }

    func testMerge_preservesPinnedWithoutChangingMuted() throws {
        let winner = ConversationBuilder()
            .withKeyHash("winner")
            .build(in: context)

        let loser = ConversationBuilder()
            .withKeyHash("loser")
            .setPinned()
            .build(in: context)

        try testStack.saveViewContext()

        XCTAssertFalse(winner.pinned)
        XCTAssertFalse(winner.muted)
        XCTAssertTrue(loser.pinned)
        XCTAssertFalse(loser.muted)

        merger.merge(from: loser, into: winner)

        XCTAssertTrue(winner.pinned, "Winner should inherit pinned status from loser")
        XCTAssertFalse(winner.muted, "Pinned state must not leak into muted state")
    }

    func testMerge_preservesMutedFromEitherConversation() throws {
        let mutedWinner = ConversationBuilder()
            .withKeyHash("muted-winner")
            .setMuted()
            .build(in: context)
        let plainLoser = ConversationBuilder()
            .withKeyHash("plain-loser")
            .build(in: context)
        let plainWinner = ConversationBuilder()
            .withKeyHash("plain-winner")
            .build(in: context)
        let mutedLoser = ConversationBuilder()
            .withKeyHash("muted-loser")
            .setMuted()
            .build(in: context)

        try testStack.saveViewContext()

        merger.merge(from: plainLoser, into: mutedWinner)
        merger.merge(from: mutedLoser, into: plainWinner)

        XCTAssertFalse(mutedWinner.pinned)
        XCTAssertTrue(mutedWinner.muted, "Winner should retain its muted status")
        XCTAssertFalse(plainWinner.pinned)
        XCTAssertTrue(plainWinner.muted, "Winner should inherit muted status from loser")
    }

    func testMerge_combinatesUnreadCounts() throws {
        let inboxLabel = LabelBuilder().inbox().build(in: context)
        let winner = ConversationBuilder()
            .withKeyHash("winner")
            .build(in: context)

        let loser = ConversationBuilder()
            .withKeyHash("loser")
            .build(in: context)

        for index in 0..<3 {
            let message = MessageBuilder()
                .withId("winner-unread-\(index)")
                .unread()
                .inConversation(winner)
                .build(in: context)
            message.addToLabels(inboxLabel)
        }

        for index in 0..<5 {
            let message = MessageBuilder()
                .withId("loser-unread-\(index)")
                .unread()
                .inConversation(loser)
                .build(in: context)
            message.addToLabels(inboxLabel)
        }

        try testStack.saveViewContext()

        merger.merge(from: loser, into: winner)

        XCTAssertEqual(winner.inboxUnreadCount, 8, "Unread counts should be combined")
    }

    func testMerge_preservesInboxStatus() throws {
        let inboxLabel = LabelBuilder().inbox().build(in: context)
        let winner = ConversationBuilder()
            .withKeyHash("winner")
            .hasInboxMessages(false)
            .build(in: context)

        let loser = ConversationBuilder()
            .withKeyHash("loser")
            .hasInboxMessages(true)
            .build(in: context)
        let inboxMessage = MessageBuilder()
            .withId("loser-inbox-message")
            .inConversation(loser)
            .build(in: context)
        inboxMessage.addToLabels(inboxLabel)

        try testStack.saveViewContext()

        XCTAssertFalse(winner.hasInbox)

        merger.merge(from: loser, into: winner)

        XCTAssertTrue(winner.hasInbox, "Winner should have inbox if either had inbox")
    }

    func testMerge_reactivatesWinnerWhenLoserIsVisible() throws {
        let inboxLabel = LabelBuilder().inbox().build(in: context)
        let winner = ConversationBuilder()
            .withKeyHash("winner")
            .archived()
            .setHidden()
            .build(in: context)

        let loser = ConversationBuilder()
            .withKeyHash("loser")
            .visible()
            .build(in: context)
        let inboxMessage = MessageBuilder()
            .withId("loser-visible-inbox-message")
            .inConversation(loser)
            .build(in: context)
        inboxMessage.addToLabels(inboxLabel)

        try testStack.saveViewContext()

        merger.merge(from: loser, into: winner)

        XCTAssertNil(winner.archivedAt)
        XCTAssertFalse(winner.hidden)
    }

    // MARK: - Duplicate Detection Tests

    func testMergeActiveDuplicates_skipsLoserReferencedByPendingSendRecord() async throws {
        let hash = calculateParticipantHash(from: ["alice@example.com"])
        let winner = ConversationBuilder()
            .withKeyHash("winner-key")
            .withParticipantHash(hash)
            .withLastMessageDate(Date())
            .build(in: context)
        _ = MessageBuilder()
            .withId("winner-msg")
            .inConversation(winner)
            .build(in: context)

        // A freshly created optimistic-send conversation: zero saved messages
        // (its optimistic message lives unsaved on the real view context) and a
        // durable send record referencing it. Merging it away would orphan the
        // optimistic message and dangle the record.
        let pendingSendShell = ConversationBuilder()
            .withKeyHash("pending-key")
            .withParticipantHash(hash)
            .withLastMessageDate(Date(timeIntervalSince1970: 1))
            .build(in: context)
        let pendingID = pendingSendShell.id
        let record = context.insertTestObject(OutboundSendMutationRecord.self)
        record.id = UUID().uuidString
        record.createdAt = Date()
        record.conversationId = pendingID
        try testStack.saveViewContext()

        await merger.mergeActiveConversationDuplicates(in: context)

        let conversations = try context.fetch(Conversation.fetchRequest())
        XCTAssertEqual(conversations.count, 2, "The pending-send conversation must not be merged away")
        XCTAssertNotNil(conversations.first { $0.id == pendingID })
    }

    func testMergeActiveDuplicates_neverUsesPendingConversationAsWinner() async throws {
        let hash = calculateParticipantHash(from: ["alice@example.com"])
        let pending = ConversationBuilder()
            .withKeyHash("pending-winner-key")
            .withParticipantHash(hash)
            .withLastMessageDate(Date(timeIntervalSince1970: 300))
            .visible()
            .build(in: context)
        let pendingID = pending.id
        for index in 0..<3 {
            _ = MessageBuilder()
                .withId("pending-winner-msg-\(index)")
                .inConversation(pending)
                .build(in: context)
        }

        let ordinaryWinner = ConversationBuilder()
            .withKeyHash("ordinary-winner-key")
            .withParticipantHash(hash)
            .withLastMessageDate(Date(timeIntervalSince1970: 200))
            .visible()
            .build(in: context)
        let ordinaryWinnerID = ordinaryWinner.id
        _ = MessageBuilder()
            .withId("ordinary-winner-msg")
            .inConversation(ordinaryWinner)
            .build(in: context)

        let ordinaryLoser = ConversationBuilder()
            .withKeyHash("ordinary-loser-key")
            .withParticipantHash(hash)
            .withLastMessageDate(Date(timeIntervalSince1970: 100))
            .visible()
            .build(in: context)
        _ = MessageBuilder()
            .withId("ordinary-loser-msg")
            .inConversation(ordinaryLoser)
            .build(in: context)

        let record = context.insertTestObject(OutboundSendMutationRecord.self)
        record.id = UUID().uuidString
        record.createdAt = Date()
        record.conversationId = pendingID
        try testStack.saveViewContext()

        await merger.mergeActiveConversationDuplicates(in: context)

        let conversations = try context.fetch(Conversation.fetchRequest())
        XCTAssertEqual(conversations.count, 2)
        let untouchedPending = try XCTUnwrap(conversations.first { $0.id == pendingID })
        XCTAssertEqual(
            Set(untouchedPending.messages?.map(\.id) ?? []),
            ["pending-winner-msg-0", "pending-winner-msg-1", "pending-winner-msg-2"]
        )
        let mergedOrdinary = try XCTUnwrap(
            conversations.first { $0.id == ordinaryWinnerID }
        )
        XCTAssertEqual(
            Set(mergedOrdinary.messages?.map(\.id) ?? []),
            ["ordinary-winner-msg", "ordinary-loser-msg"]
        )
    }

    func testMergeActiveDuplicates_retargetsPendingActionFromLoser() async throws {
        let hash = calculateParticipantHash(from: ["alice@example.com"])
        let winner = ConversationBuilder()
            .withKeyHash("pending-action-winner-key")
            .withParticipantHash(hash)
            .withLastMessageDate(Date(timeIntervalSince1970: 300))
            .visible()
            .build(in: context)
        let winnerID = winner.id
        for index in 0..<2 {
            _ = MessageBuilder()
                .withId("pending-action-winner-\(index)")
                .inConversation(winner)
                .build(in: context)
        }

        let loser = ConversationBuilder()
            .withKeyHash("pending-action-loser-key")
            .withParticipantHash(hash)
            .withLastMessageDate(Date(timeIntervalSince1970: 100))
            .visible()
            .build(in: context)
        let loserID = loser.id
        _ = MessageBuilder()
            .withId("pending-action-loser-message")
            .inConversation(loser)
            .build(in: context)

        let payload = #"{"messageIds":["pending-action-loser-message"]}"#
        PendingActionBuilder()
            .withActionType(PendingAction.ActionType.archiveConversation.rawValue)
            .forConversation(loserID)
            .withPayload(payload)
            .pending()
            .build(in: context)
        try testStack.saveViewContext()

        await merger.mergeActiveConversationDuplicates(in: context)

        let verificationContext = testStack.newBackgroundContext()
        let state = try await verificationContext.perform {
            let conversations = try verificationContext.fetch(Conversation.fetchRequest())
            let action = try XCTUnwrap(
                verificationContext.fetch(PendingAction.fetchRequest()).first
            )
            return (
                Set(conversations.map(\.id)),
                Set(conversations.first { $0.id == winnerID }?.messages?.map(\.id) ?? []),
                action.conversationId,
                action.payload
            )
        }

        XCTAssertEqual(state.0, [winnerID])
        XCTAssertEqual(
            state.1,
            [
                "pending-action-winner-0",
                "pending-action-winner-1",
                "pending-action-loser-message"
            ]
        )
        XCTAssertEqual(state.2, winnerID)
        XCTAssertEqual(state.3, payload)
    }

    func testRemoveDuplicateConversations_skipsPendingLoserButMergesOrdinaryLoser() async throws {
        let sharedKeyHash = "pending-protected-duplicate-key"
        let winner = ConversationBuilder()
            .withKeyHash(sharedKeyHash)
            .withLastMessageDate(Date(timeIntervalSince1970: 300))
            .visible()
            .build(in: context)
        _ = MessageBuilder()
            .withId("pending-protected-winner-1")
            .inConversation(winner)
            .build(in: context)
        _ = MessageBuilder()
            .withId("pending-protected-winner-2")
            .inConversation(winner)
            .build(in: context)

        let ordinaryLoser = ConversationBuilder()
            .withKeyHash(sharedKeyHash)
            .withLastMessageDate(Date(timeIntervalSince1970: 200))
            .visible()
            .build(in: context)
        _ = MessageBuilder()
            .withId("pending-protected-ordinary-loser")
            .inConversation(ordinaryLoser)
            .build(in: context)

        let pendingLoser = ConversationBuilder()
            .withKeyHash(sharedKeyHash)
            .withLastMessageDate(Date(timeIntervalSince1970: 100))
            .visible()
            .build(in: context)
        let winnerID = winner.id
        let ordinaryLoserID = ordinaryLoser.id
        let pendingLoserID = pendingLoser.id
        let record = context.insertTestObject(OutboundSendMutationRecord.self)
        record.id = UUID().uuidString
        record.createdAt = Date()
        record.conversationId = pendingLoserID
        try testStack.saveViewContext()

        await merger.removeDuplicateConversations(in: context)

        let verificationContext = testStack.newBackgroundContext()
        let state = try await verificationContext.perform {
            let conversations = try verificationContext.fetch(Conversation.fetchRequest())
            let records = try verificationContext.fetch(OutboundSendMutationRecord.fetchRequest())
            let remainingIDs = Set(conversations.map(\.id))
            let winnerMessageIDs = Set(
                conversations.first { $0.id == winnerID }?
                    .messages?
                    .map(\.id) ?? []
            )
            return (remainingIDs, winnerMessageIDs, records.compactMap(\.conversationId))
        }

        XCTAssertEqual(state.0, [winnerID, pendingLoserID])
        XCTAssertFalse(state.0.contains(ordinaryLoserID))
        XCTAssertEqual(
            state.1,
            [
                "pending-protected-winner-1",
                "pending-protected-winner-2",
                "pending-protected-ordinary-loser"
            ]
        )
        XCTAssertEqual(state.2, [pendingLoserID])
    }

    func testRemoveDuplicates_detectsDuplicateKeyHashes() throws {
        let sharedKeyHash = "duplicate-keyhash-123"

        // Create 3 conversations with same keyHash
        let _ = ConversationBuilder()
            .withKeyHash(sharedKeyHash)
            .withDisplayName("Conv 1")
            .build(in: context)

        let _ = ConversationBuilder()
            .withKeyHash(sharedKeyHash)
            .withDisplayName("Conv 2")
            .build(in: context)

        let _ = ConversationBuilder()
            .withKeyHash(sharedKeyHash)
            .withDisplayName("Conv 3")
            .build(in: context)

        // Create 1 unique conversation
        let _ = ConversationBuilder()
            .withKeyHash("unique-keyhash")
            .withDisplayName("Unique Conv")
            .build(in: context)

        try testStack.saveViewContext()

        // Verify we have 4 conversations before merge
        let beforeRequest = Conversation.fetchRequest()
        let beforeCount = try context.count(for: beforeRequest)
        XCTAssertEqual(beforeCount, 4)
    }
}
