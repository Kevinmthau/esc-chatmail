import XCTest
import CoreData
@testable import esc_chatmail

final class MessagePersisterUpdateTests: XCTestCase {
    private var testStack: TestCoreDataStack!
    private var context: NSManagedObjectContext!
    private var persister: MessagePersister!

    override func setUp() {
        super.setUp()
        testStack = TestCoreDataStack()
        context = testStack.viewContext
        persister = MessagePersister()
    }

    override func tearDown() {
        persister = nil
        context = nil
        testStack = nil
        super.tearDown()
    }

    func testUpdateExistingMessage_updatesNewsletterClassification() async {
        let conversation = ConversationBuilder.simple(in: context)
        let existingMessage = MessageBuilder()
            .withId("message-newsletter-update")
            .inConversation(conversation)
            .build(in: context)
        existingMessage.isNewsletter = false

        let processedMessage = ProcessedMessage(
            id: existingMessage.id,
            gmThreadId: existingMessage.gmThreadId,
            snippet: "Updated snippet",
            cleanedSnippet: "Updated snippet",
            internalDate: existingMessage.internalDate,
            headers: ProcessedHeaders(),
            htmlBody: nil,
            plainTextBody: existingMessage.bodyText,
            labelIds: [],
            isUnread: false,
            isNewsletter: true,
            hasAttachments: false,
            attachmentInfo: []
        )

        let didUpdate = await persister.updateExistingMessage(
            processedMessage,
            labelIds: nil,
            in: context
        )

        XCTAssertTrue(didUpdate)
        XCTAssertTrue(existingMessage.isNewsletter)
    }

    func testCreateNewMessage_reusesConversationForSameGmThreadId_evenWhenParticipantsDiffer() async throws {
        let threadId = "thread-join-123"
        let existingConversation = ConversationBuilder.simple(in: context)
        _ = MessageBuilder()
            .withId("existing-message")
            .withThreadId(threadId)
            .inConversation(existingConversation)
            .build(in: context)

        try testStack.saveViewContext()

        var headers = ProcessedHeaders()
        headers.subject = "Re: private lesson"
        headers.from = "Kevin Thau <kmthau@gmail.com>"
        headers.to = [EmailAddress(email: "RIRC@advantagetennisclubs.com", displayName: nil)]
        headers.isFromMe = true

        let processedMessage = ProcessedMessage(
            id: "new-message",
            gmThreadId: threadId,
            snippet: "Wonderful. Thank you so much.",
            cleanedSnippet: "Wonderful. Thank you so much.",
            internalDate: Date(),
            headers: headers,
            htmlBody: nil,
            plainTextBody: "Wonderful. Thank you so much.",
            labelIds: [],
            isUnread: false,
            isNewsletter: false,
            hasAttachments: false,
            attachmentInfo: []
        )

        try await persister.createNewMessage(
            processedMessage,
            labelIds: nil,
            myAliases: [normalizedEmail("kmthau@gmail.com")],
            in: context
        )

        let conversationCount = try context.count(for: Conversation.fetchRequest())
        XCTAssertEqual(conversationCount, 1, "Message should join the existing conversation, not create a new one")

        let fetch = Message.fetchRequest()
        fetch.predicate = NSPredicate(format: "id == %@", "new-message")
        fetch.fetchLimit = 1
        let saved = try context.fetch(fetch).first

        XCTAssertEqual(saved?.conversation?.objectID, existingConversation.objectID)
    }
}
