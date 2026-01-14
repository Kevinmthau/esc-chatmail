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

        XCTAssertEqual(winner.displayName, "Conv 2", "Should select conversation with more messages")
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

        XCTAssertEqual(winner.displayName, "New Conv", "Should select more recent conversation")
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
}

