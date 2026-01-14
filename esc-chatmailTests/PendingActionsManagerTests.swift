import XCTest
import CoreData
@testable import esc_chatmail

/// Tests for PendingActionsManager using in-memory Core Data stack.
///
/// Note: Full integration tests with PendingActionsManager require CoreDataStackProtocol
/// to be introduced. These tests focus on:
/// - Test infrastructure validation
/// - Core Data entity operations with builders
/// - Query logic validation
final class PendingActionsManagerTests: XCTestCase {

    var testStack: TestCoreDataStack!
    var context: NSManagedObjectContext!

    override func setUp() {
        super.setUp()
        testStack = TestCoreDataStack()
        context = testStack.viewContext
    }

    override func tearDown() {
        context = nil
        testStack = nil
        super.tearDown()
    }

    // MARK: - Test Infrastructure Tests

    func testTestCoreDataStack_createsValidContext() {
        XCTAssertNotNil(testStack.viewContext)
        XCTAssertNotNil(testStack.newBackgroundContext())
    }

    func testTestCoreDataStack_canSaveEntities() throws {
        // Create a pending action
        let action = PendingActionBuilder()
            .markAsRead()
            .forMessage("test-123")
            .pending()
            .build(in: context)

        // Save
        try testStack.saveViewContext()

        // Verify it can be fetched
        let request = PendingAction.fetchRequest()
        let results = try context.fetch(request)

        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.messageId, "test-123")
        XCTAssertEqual(results.first?.actionType, "markRead")
        XCTAssertEqual(results.first?.status, "pending")
    }

    func testTestCoreDataStack_isolatesBetweenInstances() throws {
        // Create entity in first stack
        let _ = PendingActionBuilder()
            .markAsRead()
            .forMessage("stack1-message")
            .build(in: context)
        try testStack.saveViewContext()

        // Create second stack
        let stack2 = TestCoreDataStack()

        // Verify second stack is empty
        let request = PendingAction.fetchRequest()
        let results = try stack2.viewContext.fetch(request)

        XCTAssertEqual(results.count, 0, "Second stack should be isolated and empty")
    }

    // MARK: - PendingAction Builder Tests

    func testPendingActionBuilder_setsAllProperties() throws {
        let conversationId = UUID()

        let action = PendingActionBuilder()
            .withId(UUID())
            .archive()
            .forConversation(conversationId)
            .failed()
            .withRetryCount(3)
            .createdMinutesAgo(5)
            .build(in: context)

        XCTAssertEqual(action.actionType, "archive")
        XCTAssertEqual(action.conversationId, conversationId)
        XCTAssertEqual(action.status, "failed")
        XCTAssertEqual(action.retryCount, 3)
        XCTAssertNotNil(action.createdAt)
    }

    func testPendingActionBuilder_createsWithPayload() throws {
        let payload = ["messageIds": ["msg1", "msg2", "msg3"]]

        let action = PendingActionBuilder()
            .withActionType("archiveConversation")
            .withPayload(payload)
            .build(in: context)

        XCTAssertNotNil(action.payload)

        // Verify payload can be decoded
        if let payloadData = action.payload?.data(using: .utf8),
           let decoded = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any],
           let messageIds = decoded["messageIds"] as? [String] {
            XCTAssertEqual(messageIds, ["msg1", "msg2", "msg3"])
        } else {
            XCTFail("Failed to decode payload")
        }
    }

    func testPendingActionBuilder_conveniences() throws {
        let simple = PendingActionBuilder.simple(in: context)
        XCTAssertEqual(simple.actionType, "markRead")
        XCTAssertEqual(simple.status, "pending")

        let failed = PendingActionBuilder.failedAction(in: context)
        XCTAssertEqual(failed.status, "failed")
        XCTAssertEqual(failed.retryCount, 1)
    }

    // MARK: - Message Builder Tests

    func testMessageBuilder_setsAllProperties() throws {
        let message = MessageBuilder()
            .withId("msg-123")
            .withThreadId("thread-456")
            .withSubject("Test Subject")
            .withSender(email: "sender@example.com", name: "John Doe")
            .withSnippet("This is a snippet...")
            .withBody("Full body text")
            .unread()
            .fromMe()
            .asNewsletter()
            .withAttachments()
            .build(in: context)

        XCTAssertEqual(message.id, "msg-123")
        XCTAssertEqual(message.gmThreadId, "thread-456")
        XCTAssertEqual(message.subject, "Test Subject")
        XCTAssertEqual(message.senderEmail, "sender@example.com")
        XCTAssertEqual(message.senderName, "John Doe")
        XCTAssertEqual(message.snippet, "This is a snippet...")
        XCTAssertEqual(message.bodyText, "Full body text")
        XCTAssertTrue(message.isUnread)
        XCTAssertTrue(message.isFromMe)
        XCTAssertTrue(message.isNewsletter)
        XCTAssertTrue(message.hasAttachments)
    }

    func testMessageBuilder_dateHelpers() throws {
        let message = MessageBuilder()
            .daysAgo(7)
            .build(in: context)

        let sevenDaysAgo = Calendar.current.date(byAdding: .day, value: -7, to: Date())!
        let difference = abs(message.internalDate.timeIntervalSince(sevenDaysAgo))

        XCTAssertLessThan(difference, 60, "Date should be approximately 7 days ago")
    }

    // MARK: - Conversation Builder Tests

    func testConversationBuilder_setsAllProperties() throws {
        let conversation = ConversationBuilder()
            .withDisplayName("Test Group")
            .withParticipantHash("abc123")
            .withSnippet("Latest message preview")
            .visible()
            .setPinned()
            .setMuted()
            .withUnreadCount(5)
            .recentlyActive()
            .build(in: context)

        XCTAssertEqual(conversation.displayName, "Test Group")
        XCTAssertEqual(conversation.participantHash, "abc123")
        XCTAssertEqual(conversation.snippet, "Latest message preview")
        XCTAssertNil(conversation.archivedAt)
        XCTAssertTrue(conversation.pinned)
        XCTAssertTrue(conversation.muted)
        XCTAssertEqual(conversation.inboxUnreadCount, 5)
        XCTAssertNotNil(conversation.lastMessageDate)
    }

    func testConversationBuilder_archivedState() throws {
        let archived = ConversationBuilder()
            .archived()
            .build(in: context)

        XCTAssertNotNil(archived.archivedAt)
    }

    // MARK: - Query Pattern Tests

    func testFetchPendingActions_filtersByStatus() throws {
        // Create actions with different statuses
        let _ = PendingActionBuilder()
            .pending()
            .forMessage("msg-1")
            .build(in: context)

        let _ = PendingActionBuilder()
            .failed()
            .forMessage("msg-2")
            .build(in: context)

        let _ = PendingActionBuilder()
            .completed()
            .forMessage("msg-3")
            .build(in: context)

        try testStack.saveViewContext()

        // Fetch pending or failed (like PendingActionsManager does)
        let request = PendingAction.fetchRequest()
        request.predicate = NSPredicate(
            format: "status == %@ OR status == %@",
            "pending", "failed"
        )

        let results = try context.fetch(request)

        XCTAssertEqual(results.count, 2)
        XCTAssertTrue(results.allSatisfy { $0.status == "pending" || $0.status == "failed" })
    }

    func testFetchPendingActions_filtersRetryCount() throws {
        // Create action under retry limit
        let _ = PendingActionBuilder()
            .failed()
            .withRetryCount(2)
            .forMessage("msg-under")
            .build(in: context)

        // Create action at retry limit
        let _ = PendingActionBuilder()
            .failed()
            .withRetryCount(5)
            .forMessage("msg-at-limit")
            .build(in: context)

        // Create action over retry limit
        let _ = PendingActionBuilder()
            .failed()
            .withRetryCount(6)
            .forMessage("msg-over")
            .build(in: context)

        try testStack.saveViewContext()

        // Fetch with retry count filter (like PendingActionsManager with maxRetries = 5)
        let request = PendingAction.fetchRequest()
        request.predicate = NSPredicate(
            format: "(status == %@ OR (status == %@ AND retryCount < %d))",
            "pending", "failed", 5
        )

        let results = try context.fetch(request)

        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.messageId, "msg-under")
    }

    func testFetchPendingActions_sortsByCreatedAt() throws {
        // Create actions in non-chronological order
        let _ = PendingActionBuilder()
            .forMessage("msg-old")
            .createdMinutesAgo(60)
            .build(in: context)

        let _ = PendingActionBuilder()
            .forMessage("msg-new")
            .createdMinutesAgo(1)
            .build(in: context)

        let _ = PendingActionBuilder()
            .forMessage("msg-middle")
            .createdMinutesAgo(30)
            .build(in: context)

        try testStack.saveViewContext()

        // Fetch sorted by createdAt
        let request = PendingAction.fetchRequest()
        request.sortDescriptors = [NSSortDescriptor(key: "createdAt", ascending: true)]

        let results = try context.fetch(request)

        XCTAssertEqual(results.count, 3)
        XCTAssertEqual(results[0].messageId, "msg-old")
        XCTAssertEqual(results[1].messageId, "msg-middle")
        XCTAssertEqual(results[2].messageId, "msg-new")
    }

    func testFetchPendingAction_byMessageIdAndType() throws {
        let _ = PendingActionBuilder()
            .markAsRead()
            .forMessage("target-msg")
            .pending()
            .build(in: context)

        let _ = PendingActionBuilder()
            .archive()
            .forMessage("target-msg")
            .pending()
            .build(in: context)

        let _ = PendingActionBuilder()
            .markAsRead()
            .forMessage("other-msg")
            .pending()
            .build(in: context)

        try testStack.saveViewContext()

        // Fetch specific action by message ID and type
        let request = PendingAction.fetchRequest()
        request.predicate = NSPredicate(
            format: "messageId == %@ AND actionType == %@ AND (status == %@ OR status == %@)",
            "target-msg", "markRead", "pending", "processing"
        )
        request.fetchLimit = 1

        let results = try context.fetch(request)

        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.messageId, "target-msg")
        XCTAssertEqual(results.first?.actionType, "markRead")
    }

    // MARK: - Async Test Helper Tests

    func testAsyncTestHelper_waitsForCompletion() throws {
        var completed = false

        try waitForAsync {
            try await Task.sleep(nanoseconds: 100_000_000) // 0.1 seconds
            completed = true
        }

        XCTAssertTrue(completed)
    }

    func testBackgroundContext_isolatesChanges() throws {
        // Create in view context
        let _ = PendingActionBuilder()
            .forMessage("view-context-msg")
            .build(in: context)

        // Don't save

        // Create background context and check
        let bgContext = testStack.newBackgroundContext()
        var bgCount = 0

        bgContext.performAndWait {
            let request = PendingAction.fetchRequest()
            bgCount = (try? bgContext.count(for: request)) ?? 0
        }

        XCTAssertEqual(bgCount, 0, "Unsaved changes should not be visible in background context")

        // Now save
        try testStack.saveViewContext()

        // Check again
        bgContext.performAndWait {
            let request = PendingAction.fetchRequest()
            bgCount = (try? bgContext.count(for: request)) ?? 0
        }

        XCTAssertEqual(bgCount, 1, "Saved changes should be visible after save")
    }
}
