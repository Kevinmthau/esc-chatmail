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
        // Create merger with a mock stack that uses our test context
        merger = ConversationMerger(coreDataStack: CoreDataStack.shared)
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

        let loser = ConversationBuilder()
            .withKeyHash("loser")
            .withLastMessageDate(newDate)
            .build(in: context)

        try testStack.saveViewContext()

        merger.merge(from: loser, into: winner)

        // Winner should now have the newer date
        XCTAssertEqual(winner.lastMessageDate, newDate)
    }

    func testMerge_preservesPinnedStatus() throws {
        let winner = ConversationBuilder()
            .withKeyHash("winner")
            .build(in: context)

        let loser = ConversationBuilder()
            .withKeyHash("loser")
            .setPinned()
            .build(in: context)

        try testStack.saveViewContext()

        XCTAssertFalse(winner.pinned)
        XCTAssertTrue(loser.pinned)

        merger.merge(from: loser, into: winner)

        XCTAssertTrue(winner.pinned, "Winner should inherit pinned status from loser")
    }

    func testMerge_combinatesUnreadCounts() throws {
        let winner = ConversationBuilder()
            .withKeyHash("winner")
            .withUnreadCount(3)
            .build(in: context)

        let loser = ConversationBuilder()
            .withKeyHash("loser")
            .withUnreadCount(5)
            .build(in: context)

        try testStack.saveViewContext()

        merger.merge(from: loser, into: winner)

        XCTAssertEqual(winner.inboxUnreadCount, 8, "Unread counts should be combined")
    }

    func testMerge_preservesInboxStatus() throws {
        let winner = ConversationBuilder()
            .withKeyHash("winner")
            .hasInboxMessages(false)
            .build(in: context)

        let loser = ConversationBuilder()
            .withKeyHash("loser")
            .hasInboxMessages(true)
            .build(in: context)

        try testStack.saveViewContext()

        XCTAssertFalse(winner.hasInbox)

        merger.merge(from: loser, into: winner)

        XCTAssertTrue(winner.hasInbox, "Winner should have inbox if either had inbox")
    }

    // MARK: - Duplicate Detection Tests

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

    func testMergeConversationsByGmThreadId_mergesConversationsSharingThread() async throws {
        let threadId = "gm-thread-merge-123"

        let loser = ConversationBuilder()
            .withKeyHash("thread-loser")
            .withLastMessageDate(Date(timeIntervalSince1970: 1))
            .build(in: context)

        let winner = ConversationBuilder()
            .withKeyHash("thread-winner")
            .withLastMessageDate(Date())
            .build(in: context)

        let msg1 = MessageBuilder()
            .withId("msg-thread-1")
            .withThreadId(threadId)
            .inConversation(loser)
            .build(in: context)

        let msg2 = MessageBuilder()
            .withId("msg-thread-2")
            .withThreadId(threadId)
            .inConversation(winner)
            .build(in: context)

        try testStack.saveViewContext()

        let mergedCount = await merger.mergeConversationsByGmThreadId(in: context, mergeChangesInto: [])
        XCTAssertEqual(mergedCount, 1, "Should merge exactly one loser conversation into the winner")

        let conversationCount = try context.count(for: Conversation.fetchRequest())
        XCTAssertEqual(conversationCount, 1, "After merge there should be a single conversation for the thread")

        XCTAssertEqual(msg1.conversation?.objectID, msg2.conversation?.objectID, "Messages in the same thread should share a conversation after merge")
    }

    func testMergeConversationsByGmThreadId_preservesForwardedConversationSplit() async throws {
        let threadId = "gm-thread-forward-preserve"

        let regularConversation = ConversationBuilder()
            .withKeyHash("regular-conversation")
            .build(in: context)

        let forwardedConversation = ConversationBuilder()
            .withKeyHash("forwarded-conversation")
            .build(in: context)

        let regularMessage = MessageBuilder()
            .withId("regular-message")
            .withThreadId(threadId)
            .withSubject("Re: Design review")
            .inConversation(regularConversation)
            .build(in: context)

        let forwardedMessage = MessageBuilder()
            .withId("forwarded-message")
            .withThreadId(threadId)
            .withSubject("Fwd: Design review")
            .inConversation(forwardedConversation)
            .build(in: context)

        try testStack.saveViewContext()

        let mergedCount = await merger.mergeConversationsByGmThreadId(in: context, mergeChangesInto: [])
        XCTAssertEqual(mergedCount, 0, "Forwarded conversation split should be preserved")

        let conversationCount = try context.count(for: Conversation.fetchRequest())
        XCTAssertEqual(conversationCount, 2, "Cleanup merge should not collapse forwarded conversations")

        XCTAssertNotEqual(
            regularMessage.conversation?.objectID,
            forwardedMessage.conversation?.objectID,
            "Forwarded and non-forwarded messages in the same Gmail thread should remain split"
        )
    }

    func testMergeConversationsByGmThreadId_preservesForwardedSplitDetectedFromBodyMarkers() async throws {
        let threadId = "gm-thread-forward-body-marker-preserve"

        let regularConversation = ConversationBuilder()
            .withKeyHash("regular-conversation-body-marker")
            .build(in: context)

        let forwardedConversation = ConversationBuilder()
            .withKeyHash("forwarded-conversation-body-marker")
            .build(in: context)

        let regularMessage = MessageBuilder()
            .withId("regular-message-body-marker")
            .withThreadId(threadId)
            .withSubject("Re: Deposit Notification (Deposit Declined)")
            .withBody("Can you help with this deposit?")
            .inConversation(regularConversation)
            .build(in: context)

        let forwardedMarkerMessage = MessageBuilder()
            .withId("forwarded-marker-message")
            .withThreadId(threadId)
            .withSubject("Re: Deposit Notification (Deposit Declined)")
            .withBody("""
                Hi Kevin,

                --- original message ---
                On February 23, 2026, 8:21 PM PST kmthau@gmail.com wrote:
                ---------- Forwarded message ---------
                """)
            .inConversation(forwardedConversation)
            .build(in: context)

        try testStack.saveViewContext()

        let mergedCount = await merger.mergeConversationsByGmThreadId(in: context, mergeChangesInto: [])
        XCTAssertEqual(mergedCount, 0, "Forwarded markers in body should preserve conversation split")

        let conversationCount = try context.count(for: Conversation.fetchRequest())
        XCTAssertEqual(conversationCount, 2, "Cleanup merge should not collapse forwarded-body-marker conversations")

        XCTAssertNotEqual(
            regularMessage.conversation?.objectID,
            forwardedMarkerMessage.conversation?.objectID
        )
    }

    func testMergeConversationsByGmThreadId_mergesOnlyNonForwardedConversationsWhenForwardedExists() async throws {
        let threadId = "gm-thread-mixed-forwarded"

        let nonForwardedConversationA = ConversationBuilder()
            .withKeyHash("non-forwarded-a")
            .withLastMessageDate(Date(timeIntervalSince1970: 1))
            .build(in: context)

        let nonForwardedConversationB = ConversationBuilder()
            .withKeyHash("non-forwarded-b")
            .withLastMessageDate(Date(timeIntervalSince1970: 2))
            .build(in: context)

        let forwardedConversation = ConversationBuilder()
            .withKeyHash("forwarded")
            .withLastMessageDate(Date(timeIntervalSince1970: 3))
            .build(in: context)

        let nonForwardedMessageA = MessageBuilder()
            .withId("non-forwarded-message-a")
            .withThreadId(threadId)
            .withSubject("Re: Team dinner")
            .inConversation(nonForwardedConversationA)
            .build(in: context)

        let nonForwardedMessageB = MessageBuilder()
            .withId("non-forwarded-message-b")
            .withThreadId(threadId)
            .withSubject("Re: Team dinner")
            .inConversation(nonForwardedConversationB)
            .build(in: context)

        let forwardedMessage = MessageBuilder()
            .withId("forwarded-message-in-mixed-thread")
            .withThreadId(threadId)
            .withSubject("Fw: Team dinner")
            .inConversation(forwardedConversation)
            .build(in: context)

        try testStack.saveViewContext()

        let mergedCount = await merger.mergeConversationsByGmThreadId(in: context, mergeChangesInto: [])
        XCTAssertEqual(mergedCount, 1, "Should still merge duplicate non-forwarded conversations")

        let conversationCount = try context.count(for: Conversation.fetchRequest())
        XCTAssertEqual(conversationCount, 2, "Forwarded conversation should remain separate from merged non-forwarded conversation")

        XCTAssertEqual(
            nonForwardedMessageA.conversation?.objectID,
            nonForwardedMessageB.conversation?.objectID,
            "Non-forwarded messages should be merged together"
        )
        XCTAssertNotEqual(
            nonForwardedMessageA.conversation?.objectID,
            forwardedMessage.conversation?.objectID,
            "Forwarded message should stay in its own conversation"
        )
    }
}
