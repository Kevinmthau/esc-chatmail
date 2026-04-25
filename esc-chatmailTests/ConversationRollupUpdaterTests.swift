import XCTest
import CoreData
@testable import esc_chatmail

final class ConversationRollupUpdaterTests: XCTestCase {
    private var testStack: TestCoreDataStack!
    private var context: NSManagedObjectContext!
    private var updater: ConversationRollupUpdater!

    override func setUp() {
        super.setUp()
        testStack = TestCoreDataStack()
        context = testStack.viewContext
        updater = ConversationRollupUpdater()
    }

    override func tearDown() {
        updater = nil
        context = nil
        testStack = nil
        super.tearDown()
    }

    func testUpdateRollups_clearsLatestInboxDateWhenNoInboxMessages() throws {
        let staleInboxDate = Date(timeIntervalSince1970: 100)
        let sentDate = Date(timeIntervalSince1970: 200)

        let conversation = ConversationBuilder()
            .withSnippet("Stale inbox preview")
            .withLastMessageDate(staleInboxDate)
            .hasInboxMessages(true)
            .visible()
            .build(in: context)
        conversation.latestInboxDate = staleInboxDate

        let sentLabel = LabelBuilder().sent().build(in: context)
        let sentMessage = MessageBuilder()
            .withId("rollup-sent-only")
            .withDate(sentDate)
            .withSnippet("Latest sent preview")
            .fromMe()
            .inConversation(conversation)
            .build(in: context)
        sentMessage.addToLabels(sentLabel)

        try context.save()

        updater.updateRollups(for: conversation, myEmail: "me@example.com")

        XCTAssertFalse(conversation.hasInbox)
        XCTAssertEqual(conversation.inboxUnreadCount, 0)
        XCTAssertNil(conversation.latestInboxDate)
        XCTAssertEqual(conversation.lastMessageDate, sentDate)
        XCTAssertEqual(conversation.snippet, "Latest sent preview")
    }

    func testUpdateRollups_clearsVisibleMetadataWhenNoVisibleMessagesRemain() throws {
        let staleDate = Date(timeIntervalSince1970: 100)
        let draftDate = Date(timeIntervalSince1970: 200)

        let conversation = ConversationBuilder()
            .withSnippet("Stale visible preview")
            .withLastMessageDate(staleDate)
            .visible()
            .build(in: context)
        conversation.latestInboxDate = staleDate

        let draftLabel = LabelBuilder().draft().build(in: context)
        let draftMessage = MessageBuilder()
            .withId("rollup-draft-only")
            .withDate(draftDate)
            .withSnippet("Draft preview should not drive rollup")
            .inConversation(conversation)
            .build(in: context)
        draftMessage.addToLabels(draftLabel)

        try context.save()

        updater.updateRollups(for: conversation, myEmail: "me@example.com")

        XCTAssertFalse(conversation.hasInbox)
        XCTAssertEqual(conversation.inboxUnreadCount, 0)
        XCTAssertNil(conversation.latestInboxDate)
        XCTAssertNil(conversation.lastMessageDate)
        XCTAssertNil(conversation.snippet)
    }
}
