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

    func testCreateNewMessage_forwardedSubject_createsNewConversationEvenWhenThreadMatches() async throws {
        let threadId = "thread-forward-123"
        let existingConversation = ConversationBuilder.simple(in: context)
        _ = MessageBuilder()
            .withId("existing-forward-message")
            .withThreadId(threadId)
            .inConversation(existingConversation)
            .build(in: context)

        try testStack.saveViewContext()

        var headers = ProcessedHeaders()
        headers.subject = "Fwd: Mario Spina"
        headers.from = "Brynn Putnam <brynn@example.com>"
        headers.to = [
            EmailAddress(email: "kristine@example.com", displayName: "Kristine"),
            EmailAddress(email: "kmthau@gmail.com", displayName: "Kevin Thau")
        ]
        headers.isFromMe = false

        let processedMessage = ProcessedMessage(
            id: "forwarded-message",
            gmThreadId: threadId,
            snippet: "Hi Kristine, can you take a look?",
            cleanedSnippet: "Hi Kristine, can you take a look?",
            internalDate: Date(),
            headers: headers,
            htmlBody: nil,
            plainTextBody: "Hi Kristine, can you take a look?",
            labelIds: [],
            isUnread: true,
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
        XCTAssertEqual(conversationCount, 2, "Forwarded messages should create a new participant-based conversation")

        let fetch = Message.fetchRequest()
        fetch.predicate = NSPredicate(format: "id == %@", "forwarded-message")
        fetch.fetchLimit = 1
        let saved = try context.fetch(fetch).first

        XCTAssertNotEqual(saved?.conversation?.objectID, existingConversation.objectID)
        XCTAssertEqual(
            saved?.conversation?.participantHash,
            calculateParticipantHash(from: ["brynn@example.com", "kristine@example.com"]),
            "Forwarded conversation should use the forward recipient/sender participant set"
        )
    }

    func testCreateNewMessage_inlineDataAttachment_isPersistedAsDownloaded() async throws {
        let inlineImageData = try XCTUnwrap(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+X2foAAAAASUVORK5CYII="))

        var headers = ProcessedHeaders()
        headers.subject = "Inline attachment"
        headers.from = "Sender <sender@example.com>"
        headers.to = [EmailAddress(email: "recipient@example.com", displayName: nil)]
        headers.isFromMe = false

        let processedMessage = ProcessedMessage(
            id: "inline-data-message",
            gmThreadId: "inline-data-thread",
            snippet: "See image",
            cleanedSnippet: "See image",
            internalDate: Date(),
            headers: headers,
            htmlBody: nil,
            plainTextBody: "See image",
            labelIds: ["INBOX"],
            isUnread: true,
            isNewsletter: false,
            hasAttachments: true,
            attachmentInfo: [
                AttachmentInfo(
                    id: "local_inline_test_attachment",
                    filename: "inline.png",
                    mimeType: "image/png",
                    size: inlineImageData.count,
                    contentId: "inline-test",
                    inlineData: inlineImageData
                )
            ]
        )

        try await persister.createNewMessage(
            processedMessage,
            labelIds: nil,
            myAliases: [normalizedEmail("recipient@example.com")],
            in: context
        )

        let request = Message.fetchRequest()
        request.predicate = NSPredicate(format: "id == %@", "inline-data-message")
        request.fetchLimit = 1
        let savedMessage = try XCTUnwrap(context.fetch(request).first)
        let savedAttachment = try XCTUnwrap(savedMessage.attachmentsArray.first)

        XCTAssertEqual(savedMessage.attachmentsArray.count, 1)
        XCTAssertEqual(savedAttachment.state, .downloaded)
        XCTAssertNotNil(savedAttachment.localURL)
        XCTAssertNotNil(savedAttachment.previewURL)
        XCTAssertEqual(savedAttachment.contentId, "inline-test")
        XCTAssertEqual(AttachmentPaths.loadData(from: savedAttachment.localURL), inlineImageData)

        AttachmentPaths.deleteFile(at: savedAttachment.localURL)
        AttachmentPaths.deleteFile(at: savedAttachment.previewURL)
    }
}
