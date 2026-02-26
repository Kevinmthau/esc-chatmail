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

    func testCreateNewMessage_forwardedMarkerInBody_createsNewConversationEvenWhenThreadMatches() async throws {
        let threadId = "thread-forward-body-marker-123"
        let existingConversation = ConversationBuilder.simple(in: context)
        _ = MessageBuilder()
            .withId("existing-thread-message")
            .withThreadId(threadId)
            .inConversation(existingConversation)
            .build(in: context)

        try testStack.saveViewContext()

        var headers = ProcessedHeaders()
        headers.subject = "Re: Deposit Notification (Deposit Declined)"
        headers.from = "Erin Hardy <erin.hardy@adviceperiod.com>"
        headers.to = [EmailAddress(email: "kmthau@gmail.com", displayName: "Kevin Thau")]
        headers.isFromMe = false

        let plainText = """
        Hi Kevin,

        Yes, I'll reach out to them about this. Will circle back.

        --- original message ---
        On February 23, 2026, 8:21 PM PST kmthau@gmail.com wrote:
        ---------- Forwarded message ---------
        """

        let processedMessage = ProcessedMessage(
            id: "forwarded-marker-reply-message",
            gmThreadId: threadId,
            snippet: "Yes, I'll reach out to them about this. Will circle back.",
            cleanedSnippet: "Yes, I'll reach out to them about this. Will circle back.",
            internalDate: Date(),
            headers: headers,
            htmlBody: nil,
            plainTextBody: plainText,
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
        XCTAssertEqual(conversationCount, 2, "Forward markers in body should create a new participant-based conversation")

        let fetch = Message.fetchRequest()
        fetch.predicate = NSPredicate(format: "id == %@", "forwarded-marker-reply-message")
        fetch.fetchLimit = 1
        let saved = try context.fetch(fetch).first

        XCTAssertNotEqual(saved?.conversation?.objectID, existingConversation.objectID)
        XCTAssertEqual(
            saved?.conversation?.participantHash,
            calculateParticipantHash(from: ["erin.hardy@adviceperiod.com"])
        )
    }

    func testCreateNewMessage_updatesConversationListIndicatorsImmediately() async throws {
        _ = LabelBuilder.inboxLabel(in: context)
        _ = LabelBuilder.unreadLabel(in: context)

        let threadId = "thread-fast-list-update"
        let oldDate = Date(timeIntervalSince1970: 1_700_000_000)
        let newDate = oldDate.addingTimeInterval(120)

        let existingConversation = ConversationBuilder()
            .withSnippet("Old snippet")
            .withLastMessageDate(oldDate)
            .withUnreadCount(0)
            .hasInboxMessages(false)
            .archived()
            .setHidden()
            .build(in: context)

        _ = MessageBuilder()
            .withId("existing-seed-message")
            .withThreadId(threadId)
            .withDate(oldDate)
            .inConversation(existingConversation)
            .build(in: context)

        var headers = ProcessedHeaders()
        headers.subject = "Re: Fast list update"
        headers.from = "Sender <sender@example.com>"
        headers.to = [EmailAddress(email: "recipient@example.com", displayName: nil)]
        headers.isFromMe = false

        let processedMessage = ProcessedMessage(
            id: "incoming-fast-list-message",
            gmThreadId: threadId,
            snippet: "Raw incoming snippet",
            cleanedSnippet: "Clean incoming snippet",
            internalDate: newDate,
            headers: headers,
            htmlBody: nil,
            plainTextBody: "Body",
            labelIds: ["INBOX", "UNREAD"],
            isUnread: true,
            isNewsletter: false,
            hasAttachments: false,
            attachmentInfo: []
        )

        try await persister.createNewMessage(
            processedMessage,
            labelIds: nil,
            myAliases: [normalizedEmail("recipient@example.com")],
            in: context
        )

        XCTAssertEqual(existingConversation.inboxUnreadCount, 1)
        XCTAssertTrue(existingConversation.hasInbox)
        XCTAssertEqual(existingConversation.latestInboxDate, newDate)
        XCTAssertEqual(existingConversation.lastMessageDate, newDate)
        XCTAssertEqual(existingConversation.snippet, "Clean incoming snippet")
        XCTAssertNil(existingConversation.archivedAt)
        XCTAssertFalse(existingConversation.hidden)
    }

    func testUpdateExistingMessage_updatesConversationUnreadIndicatorsImmediately() async {
        let inboxLabel = LabelBuilder.inboxLabel(in: context)
        let unreadLabel = LabelBuilder.unreadLabel(in: context)
        let messageDate = Date(timeIntervalSince1970: 1_700_001_000)

        let conversation = ConversationBuilder()
            .withSnippet("Old snippet")
            .withLastMessageDate(messageDate)
            .hasInboxMessages(true)
            .withUnreadCount(1)
            .build(in: context)

        let existingMessage = MessageBuilder()
            .withId("existing-label-update-message")
            .withDate(messageDate)
            .withSnippet("Old message snippet")
            .inConversation(conversation)
            .build(in: context)
        existingMessage.isUnread = true
        existingMessage.addToLabels(inboxLabel)
        existingMessage.addToLabels(unreadLabel)

        let processedMessage = ProcessedMessage(
            id: existingMessage.id,
            gmThreadId: existingMessage.gmThreadId,
            snippet: "Updated raw snippet",
            cleanedSnippet: "Updated clean snippet",
            internalDate: messageDate,
            headers: ProcessedHeaders(),
            htmlBody: nil,
            plainTextBody: existingMessage.bodyText,
            labelIds: ["INBOX"],
            isUnread: false,
            isNewsletter: false,
            hasAttachments: false,
            attachmentInfo: []
        )

        let didUpdate = await persister.updateExistingMessage(
            processedMessage,
            labelIds: nil,
            in: context
        )

        XCTAssertTrue(didUpdate)
        XCTAssertEqual(conversation.inboxUnreadCount, 0)
        XCTAssertTrue(conversation.hasInbox)
        XCTAssertEqual(conversation.latestInboxDate, messageDate)
        XCTAssertEqual(conversation.snippet, "Updated clean snippet")
    }

    func testUpdateExistingMessage_removingInboxLabelRecomputesConversationInboxIndicators() async {
        let inboxLabel = LabelBuilder.inboxLabel(in: context)
        let messageDate = Date(timeIntervalSince1970: 1_700_002_000)

        let conversation = ConversationBuilder()
            .withSnippet("Old snippet")
            .withLastMessageDate(messageDate)
            .hasInboxMessages(true)
            .withUnreadCount(0)
            .build(in: context)

        let existingMessage = MessageBuilder()
            .withId("existing-remove-inbox-message")
            .withDate(messageDate)
            .inConversation(conversation)
            .build(in: context)
        existingMessage.isUnread = false
        existingMessage.addToLabels(inboxLabel)

        let processedMessage = ProcessedMessage(
            id: existingMessage.id,
            gmThreadId: existingMessage.gmThreadId,
            snippet: existingMessage.snippet,
            cleanedSnippet: existingMessage.cleanedSnippet,
            internalDate: messageDate,
            headers: ProcessedHeaders(),
            htmlBody: nil,
            plainTextBody: existingMessage.bodyText,
            labelIds: [],
            isUnread: false,
            isNewsletter: false,
            hasAttachments: false,
            attachmentInfo: []
        )

        let didUpdate = await persister.updateExistingMessage(
            processedMessage,
            labelIds: nil,
            in: context
        )

        XCTAssertTrue(didUpdate)
        XCTAssertFalse(conversation.hasInbox)
        XCTAssertEqual(conversation.inboxUnreadCount, 0)
        XCTAssertNil(conversation.latestInboxDate)
    }

    func testUpdateExistingMessage_mergesMissingServerAttachmentsForOptimisticSentMessage() async {
        let conversation = ConversationBuilder.simple(in: context)
        let existingMessage = MessageBuilder()
            .withId("message-attachment-merge")
            .inConversation(conversation)
            .build(in: context)
        existingMessage.hasAttachments = true

        _ = AttachmentBuilder()
            .withId("local_inline_existing")
            .withFilename("optimistic-inline.png")
            .withMimeType("image/png")
            .withContentId("ii_mm3y7cq08")
            .downloaded()
            .forMessage(existingMessage)
            .build(in: context)

        let processedMessage = ProcessedMessage(
            id: existingMessage.id,
            gmThreadId: existingMessage.gmThreadId,
            snippet: existingMessage.snippet,
            cleanedSnippet: existingMessage.cleanedSnippet,
            internalDate: existingMessage.internalDate,
            headers: ProcessedHeaders(),
            htmlBody: nil,
            plainTextBody: existingMessage.bodyText,
            labelIds: [],
            isUnread: existingMessage.isUnread,
            isNewsletter: existingMessage.isNewsletter,
            hasAttachments: true,
            attachmentInfo: [
                // Same CID as optimistic local attachment; should dedupe.
                AttachmentInfo(
                    id: "real_attachment_1",
                    filename: "inline-existing.png",
                    mimeType: "image/png",
                    size: 120,
                    contentId: "<ii_mm3y7cq08>"
                ),
                AttachmentInfo(
                    id: "real_attachment_2",
                    filename: "inline-2.png",
                    mimeType: "image/png",
                    size: 121,
                    contentId: "ii_19c9bbffa4da5b773191"
                ),
                AttachmentInfo(
                    id: "real_attachment_3",
                    filename: "inline-3.png",
                    mimeType: "image/png",
                    size: 122,
                    contentId: "ii_19c9bbffa4d86c910832"
                )
            ]
        )

        let didUpdate = await persister.updateExistingMessage(
            processedMessage,
            labelIds: nil,
            in: context
        )

        XCTAssertTrue(didUpdate)

        let attachments = existingMessage.attachmentsArray
        XCTAssertEqual(attachments.count, 3)

        let normalizedCIDs = attachments.compactMap { attachment -> String? in
            guard let contentId = attachment.contentId else { return nil }
            return contentId
                .trimmingCharacters(in: CharacterSet(charactersIn: "<> \t\r\n"))
                .lowercased()
        }

        XCTAssertEqual(normalizedCIDs.filter { $0 == "ii_mm3y7cq08" }.count, 1)
        XCTAssertTrue(normalizedCIDs.contains("ii_19c9bbffa4da5b773191"))
        XCTAssertTrue(normalizedCIDs.contains("ii_19c9bbffa4d86c910832"))
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
