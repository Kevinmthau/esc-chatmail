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

    func testUpdateRollups_keepsActiveConversationVisibleWhenLatestMessageIsOutgoing() throws {
        let oldDate = Date(timeIntervalSince1970: 100)
        let sentDate = Date(timeIntervalSince1970: 200)

        let conversation = ConversationBuilder()
            .withSnippet("Old archived incoming")
            .withLastMessageDate(oldDate)
            .visible()
            .hasInboxMessages(false)
            .build(in: context)

        MessageBuilder()
            .withId("old-received-message")
            .withDate(oldDate)
            .withSnippet("Old archived incoming")
            .inConversation(conversation)
            .build(in: context)

        let sentLabel = LabelBuilder().sent().build(in: context)
        let sentMessage = MessageBuilder()
            .withId("latest-sent-message")
            .withDate(sentDate)
            .withSnippet("Latest outgoing")
            .fromMe()
            .inConversation(conversation)
            .build(in: context)
        sentMessage.addToLabels(sentLabel)

        try context.save()

        updater.updateRollups(for: conversation, myEmail: "me@example.com")

        XCTAssertFalse(conversation.hasInbox)
        XCTAssertNil(conversation.archivedAt)
        XCTAssertFalse(conversation.hidden)
        XCTAssertEqual(conversation.lastMessageDate, sentDate)
        XCTAssertEqual(conversation.snippet, "Latest outgoing")
    }

    func testUpdateDisplayNameOnly_noRealNameUsesEmailAddress() throws {
        let conversation = ConversationBuilder()
            .withDisplayName("John Smith")
            .build(in: context)
        addConversationParticipant(
            email: "john.smith@example.com",
            displayName: "John Smith",
            to: conversation
        )
        try context.save()

        updater.updateDisplayNameOnly(for: conversation, myEmail: "me@example.com")

        XCTAssertEqual(conversation.displayName, "john.smith@example.com")
    }

    func testUpdateDisplayNameOnly_usesExplicitHeaderDisplayName() throws {
        let conversation = ConversationBuilder()
            .withDisplayName("Unknown Contact")
            .build(in: context)
        addConversationParticipant(
            email: "john.smith@example.com",
            displayName: "John Smith",
            to: conversation
        )
        MessageBuilder()
            .withSender(email: "john.smith@example.com", name: "John Smith")
            .inConversation(conversation)
            .build(in: context)
        try context.save()

        updater.updateDisplayNameOnly(for: conversation, myEmail: "me@example.com")

        XCTAssertEqual(conversation.displayName, "John Smith")
    }

    func testUpdateDisplayNameOnly_usesExplicitBrandNameMatchingEmailLocalPart() throws {
        let conversation = ConversationBuilder()
            .withDisplayName("Unknown Contact")
            .build(in: context)
        addConversationParticipant(
            email: "a16z@substack.com",
            displayName: "a16z",
            to: conversation
        )
        _ = MessageBuilder()
            .withSender(email: "a16z@substack.com", name: "a16z")
            .inConversation(conversation)
            .build(in: context)
        try context.save()

        updater.updateDisplayNameOnly(for: conversation, myEmail: "me@example.com")

        XCTAssertEqual(conversation.displayName, "a16z")
    }

    func testUpdateDisplayNameOnly_usesStoredNameWhenHeaderIsPlainRawLocalPart() throws {
        let conversation = ConversationBuilder()
            .withDisplayName("Unknown Contact")
            .build(in: context)
        addConversationParticipant(
            email: "john@example.com",
            displayName: "John Appleseed",
            to: conversation
        )
        _ = MessageBuilder()
            .withSender(email: "john@example.com", name: "john")
            .inConversation(conversation)
            .build(in: context)
        try context.save()

        updater.updateDisplayNameOnly(for: conversation, myEmail: "me@example.com")

        XCTAssertEqual(conversation.displayName, "John Appleseed")
    }

    func testUpdateDisplayNameOnly_upgradesLegacyAddressDerivedNameToStoredRealName() throws {
        let conversation = ConversationBuilder()
            .withDisplayName("John Smith")
            .build(in: context)
        addConversationParticipant(
            email: "john.smith@example.com",
            displayName: "Address Book John",
            to: conversation
        )
        try context.save()

        updater.updateDisplayNameOnly(for: conversation, myEmail: "me@example.com")

        XCTAssertEqual(conversation.displayName, "Address Book John")
    }

    func testUpdateDisplayNameOnly_groupOmitsAddressDerivedNamesAndShowsCount() throws {
        let conversation = ConversationBuilder()
            .withDisplayName("John & Sarah")
            .build(in: context)
        addConversationParticipant(
            email: "john.smith@example.com",
            displayName: "John Smith",
            to: conversation
        )
        addConversationParticipant(
            email: "sarah@example.com",
            displayName: "Sarah Connor",
            to: conversation
        )
        try context.save()

        updater.updateDisplayNameOnly(for: conversation, myEmail: "me@example.com")

        XCTAssertEqual(conversation.displayName, "Sarah Connor +1")
    }

    func testUpdateDisplayNameOnly_groupWithNoRealNamesUsesEmailAddresses() throws {
        let conversation = ConversationBuilder()
            .withDisplayName("John & Jane")
            .build(in: context)
        addConversationParticipant(
            email: "john.smith@example.com",
            displayName: "John Smith",
            to: conversation
        )
        addConversationParticipant(
            email: "jane.doe@example.com",
            displayName: "Jane Doe",
            to: conversation
        )
        try context.save()

        updater.updateDisplayNameOnly(for: conversation, myEmail: "me@example.com")

        XCTAssertEqual(conversation.displayName, "jane.doe@example.com, john.smith@example.com")
    }

    @discardableResult
    private func addConversationParticipant(
        email: String,
        displayName: String?,
        to conversation: Conversation
    ) -> Person {
        let person = PersonBuilder()
            .withEmail(email)
            .withDisplayName(displayName)
            .build(in: context)
        let participant = context.insertTestObject(ConversationParticipant.self)
        participant.id = UUID()
        participant.participantRole = .normal
        participant.person = person
        participant.conversation = conversation
        return person
    }
}
