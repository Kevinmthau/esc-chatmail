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
        persister = MessagePersister(photoPrefetcher: { _ in })
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

    func testSaveMessage_newHTMLMessage_savesHTMLOnce() async throws {
        var headers = ProcessedHeaders()
        headers.subject = "HTML message"
        headers.from = "Sender <sender@example.com>"
        headers.to = [EmailAddress(email: "recipient@example.com", displayName: nil)]
        headers.isFromMe = false

        let processedMessage = ProcessedMessage(
            id: "new-html-message",
            gmThreadId: "new-html-thread",
            snippet: "HTML snippet",
            cleanedSnippet: "HTML snippet",
            internalDate: Date(),
            headers: headers,
            htmlBody: "<html><body><p>Hello</p></body></html>",
            plainTextBody: "Hello",
            labelIds: ["INBOX"],
            isUnread: true,
            isNewsletter: false,
            hasAttachments: false,
            attachmentInfo: []
        )
        let htmlSaveSpy = HTMLSaveSpy()
        let htmlPersister = MessagePersister(
            messageProcessor: StubMessageProcessor(processedMessage: processedMessage),
            saveHTML: { html, messageId in
                htmlSaveSpy.save(html, messageId: messageId)
            },
            photoPrefetcher: { _ in }
        )

        await htmlPersister.saveMessage(
            GmailMessage(
                id: processedMessage.id,
                threadId: processedMessage.gmThreadId,
                labelIds: processedMessage.labelIds,
                snippet: processedMessage.snippet,
                historyId: nil,
                internalDate: "\(Int(processedMessage.internalDate.timeIntervalSince1970 * 1000))",
                payload: nil,
                sizeEstimate: nil
            ),
            myAliases: [normalizedEmail("recipient@example.com")],
            in: context
        )

        let request = Message.fetchRequest()
        request.predicate = NSPredicate(format: "id == %@", processedMessage.id)
        request.fetchLimit = 1

        let savedMessage = try XCTUnwrap(context.fetch(request).first)
        XCTAssertEqual(htmlSaveSpy.recordedCallCount, 1)
        XCTAssertEqual(savedMessage.bodyStorageURI, "file:///tmp/\(processedMessage.id).html")
    }

    func testCreateNewMessage_onBackgroundContext_persistsMessageAndConversation() async throws {
        let backgroundContext = testStack.newBackgroundContext()
        var headers = ProcessedHeaders()
        headers.subject = "Background sync message"
        headers.from = "Sender <sender@example.com>"
        headers.to = [EmailAddress(email: "recipient@example.com", displayName: nil)]
        headers.isFromMe = false

        let processedMessage = ProcessedMessage(
            id: "background-create-message",
            gmThreadId: "background-thread-1",
            snippet: "Created on a background context",
            cleanedSnippet: "Created on a background context",
            internalDate: Date(),
            headers: headers,
            htmlBody: nil,
            plainTextBody: "Created on a background context",
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
            in: backgroundContext
        )
        try await backgroundContext.perform {
            try backgroundContext.save()
        }

        let fetch = Message.fetchRequest()
        fetch.predicate = NSPredicate(format: "id == %@", processedMessage.id)
        fetch.fetchLimit = 1

        let saved = try XCTUnwrap(context.fetch(fetch).first)
        XCTAssertEqual(saved.subject, "Background sync message")
        XCTAssertEqual(saved.conversation?.participantHash, calculateParticipantHash(from: ["sender@example.com"]))
        XCTAssertTrue(saved.isUnread)
    }

    func testUpdateExistingMessage_onBackgroundContext_persistsChanges() async throws {
        let conversation = ConversationBuilder.simple(in: context)
        _ = MessageBuilder()
            .withId("background-update-message")
            .inConversation(conversation)
            .build(in: context)
        try testStack.saveViewContext()

        let backgroundContext = testStack.newBackgroundContext()
        var headers = ProcessedHeaders()
        headers.subject = "Updated subject"
        headers.from = "Sender <sender@example.com>"
        headers.to = [EmailAddress(email: "recipient@example.com", displayName: nil)]
        headers.isFromMe = false

        let processedMessage = ProcessedMessage(
            id: "background-update-message",
            gmThreadId: "thread-update-background",
            snippet: "Updated on background context",
            cleanedSnippet: "Updated on background context",
            internalDate: Date(),
            headers: headers,
            htmlBody: nil,
            plainTextBody: "Updated on background context",
            labelIds: ["INBOX"],
            isUnread: false,
            isNewsletter: true,
            hasAttachments: false,
            attachmentInfo: []
        )

        let didUpdate = await persister.updateExistingMessage(
            processedMessage,
            labelIds: nil,
            in: backgroundContext
        )
        XCTAssertTrue(didUpdate)

        try await backgroundContext.perform {
            try backgroundContext.save()
        }

        let fetch = Message.fetchRequest()
        fetch.predicate = NSPredicate(format: "id == %@", processedMessage.id)
        fetch.fetchLimit = 1

        let saved = try XCTUnwrap(context.fetch(fetch).first)
        XCTAssertEqual(saved.snippet, "Updated on background context")
        XCTAssertTrue(saved.isNewsletter)
        XCTAssertFalse(saved.isUnread)
    }

    func testUpdateExistingMessage_enrichesParticipantDisplayNameFromRefreshedFromHeader() async throws {
        let senderEmail = "info@bonbonwhims.com"
        let conversation = ConversationBuilder()
            .withParticipantHash(calculateParticipantHash(from: [senderEmail]))
            .withDisplayName("Info")
            .build(in: context)
        let sender = PersonBuilder.emailOnly(senderEmail, in: context)
        addConversationParticipant(person: sender, to: conversation)
        let existingMessage = MessageBuilder()
            .withId("bonbonwhims-message")
            .withThreadId("bonbonwhims-thread")
            .withSender(email: senderEmail, name: nil)
            .inConversation(conversation)
            .build(in: context)
        addMessageParticipant(person: sender, kind: .from, to: existingMessage)

        var headers = ProcessedHeaders()
        headers.subject = "Our Totally Spies! Collab is here"
        headers.from = "BONBONWHIMS <\(senderEmail)>"
        headers.to = [EmailAddress(email: "kmthau@gmail.com", displayName: "Kevin Thau")]
        headers.isFromMe = false

        let processedMessage = ProcessedMessage(
            id: existingMessage.id,
            gmThreadId: existingMessage.gmThreadId,
            snippet: existingMessage.snippet,
            cleanedSnippet: existingMessage.cleanedSnippet,
            internalDate: existingMessage.internalDate,
            headers: headers,
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
        XCTAssertEqual(existingMessage.senderName, "BONBONWHIMS")
        XCTAssertEqual(sender.displayName, "BONBONWHIMS")

        ConversationRollupUpdater().updateDisplayNameOnly(
            for: conversation,
            myEmail: "kmthau@gmail.com"
        )
        XCTAssertEqual(conversation.displayName, "BONBONWHIMS")
    }

    func testCreateNewMessage_sameGmThreadIdWithParticipantDrift_reusesExistingConversation() async throws {
        let threadId = "thread-join-123"
        let existingConversation = ConversationBuilder()
            .withParticipantHash(calculateParticipantHash(from: ["rirc@advantagetennisclubs.com"]))
            .build(in: context)
        _ = MessageBuilder()
            .withId("existing-message")
            .withThreadId(threadId)
            .inConversation(existingConversation)
            .build(in: context)

        try testStack.saveViewContext()

        var headers = ProcessedHeaders()
        headers.subject = "Re: private lesson"
        headers.from = "RIRC <RIRC@advantagetennisclubs.com>"
        headers.to = [
            EmailAddress(email: "kmthau@gmail.com", displayName: nil),
            EmailAddress(email: "assistant@advantagetennisclubs.com", displayName: nil)
        ]
        headers.isFromMe = false

        let processedMessage = ProcessedMessage(
            id: "new-message",
            gmThreadId: threadId,
            snippet: "Wonderful. Thank you so much.",
            cleanedSnippet: "Wonderful. Thank you so much.",
            internalDate: Date(),
            headers: headers,
            htmlBody: nil,
            plainTextBody: "Wonderful. Thank you so much.",
            labelIds: ["INBOX", "UNREAD"],
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
        XCTAssertEqual(conversationCount, 1, "Non-forwarded Gmail mail should stay attached to the existing same-thread conversation")

        let fetch = Message.fetchRequest()
        fetch.predicate = NSPredicate(format: "id == %@", "new-message")
        fetch.fetchLimit = 1
        let saved = try XCTUnwrap(context.fetch(fetch).first)

        XCTAssertEqual(saved.conversation?.objectID, existingConversation.objectID)
    }

    func testCreateNewMessage_nonForwardedReplyReusesRegularConversationWhenForwardedSplitIsNewest() async throws {
        let threadId = "thread-forwarded-split-newest"
        let regularConversation = ConversationBuilder()
            .withParticipantHash(calculateParticipantHash(from: ["friend@example.com"]))
            .build(in: context)
        let forwardedConversation = ConversationBuilder()
            .withParticipantHash(calculateParticipantHash(from: [
                "friend@example.com",
                "teammate@example.com"
            ]))
            .build(in: context)

        _ = MessageBuilder()
            .withId("regular-thread-message")
            .withThreadId(threadId)
            .withSubject("Re: Team dinner")
            .withDate(Date(timeIntervalSince1970: 1_700_000_000))
            .inConversation(regularConversation)
            .build(in: context)

        _ = MessageBuilder()
            .withId("forwarded-thread-message")
            .withThreadId(threadId)
            .withSubject("Fwd: Team dinner")
            .withDate(Date(timeIntervalSince1970: 1_700_000_120))
            .inConversation(forwardedConversation)
            .build(in: context)

        try testStack.saveViewContext()

        var headers = ProcessedHeaders()
        headers.subject = "Re: Team dinner"
        headers.from = "Friend <friend@example.com>"
        headers.to = [EmailAddress(email: "me@example.com", displayName: nil)]
        headers.isFromMe = false

        let processedMessage = ProcessedMessage(
            id: "new-regular-reply",
            gmThreadId: threadId,
            snippet: "Sounds good to me.",
            cleanedSnippet: "Sounds good to me.",
            internalDate: Date(timeIntervalSince1970: 1_700_000_240),
            headers: headers,
            htmlBody: nil,
            plainTextBody: "Sounds good to me.",
            labelIds: ["INBOX"],
            isUnread: true,
            isNewsletter: false,
            hasAttachments: false,
            attachmentInfo: []
        )

        try await persister.createNewMessage(
            processedMessage,
            labelIds: nil,
            myAliases: [normalizedEmail("me@example.com")],
            in: context
        )

        let fetch = Message.fetchRequest()
        fetch.predicate = NSPredicate(format: "id == %@", processedMessage.id)
        fetch.fetchLimit = 1
        let saved = try XCTUnwrap(context.fetch(fetch).first)

        XCTAssertEqual(saved.conversation?.objectID, regularConversation.objectID)
        XCTAssertNotEqual(saved.conversation?.objectID, forwardedConversation.objectID)
        XCTAssertEqual(try context.count(for: Conversation.fetchRequest()), 2)
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

    func testCreateNewMessage_sentOnlyMessageInArchivedThread_reactivatesConversation() async throws {
        let threadId = "thread-archived-sent-only"
        let archivedConversation = ConversationBuilder()
            .withSnippet("Old archived snippet")
            .withLastMessageDate(Date(timeIntervalSince1970: 1_700_100_000))
            .archived()
            .setHidden()
            .build(in: context)

        _ = MessageBuilder()
            .withId("seed-archived-message")
            .withThreadId(threadId)
            .inConversation(archivedConversation)
            .build(in: context)

        var headers = ProcessedHeaders()
        headers.subject = "Re: Archived thread"
        headers.from = "Me <me@example.com>"
        headers.to = [EmailAddress(email: "friend@example.com", displayName: nil)]
        headers.isFromMe = true

        let processedMessage = ProcessedMessage(
            id: "sent-only-archived-thread-message",
            gmThreadId: threadId,
            snippet: "Sent from another client",
            cleanedSnippet: "Sent from another client",
            internalDate: Date(timeIntervalSince1970: 1_700_100_120),
            headers: headers,
            htmlBody: nil,
            plainTextBody: "Sent from another client",
            labelIds: ["SENT"],
            isUnread: false,
            isNewsletter: false,
            hasAttachments: false,
            attachmentInfo: []
        )

        try await persister.createNewMessage(
            processedMessage,
            labelIds: nil,
            myAliases: [normalizedEmail("me@example.com")],
            in: context
        )

        XCTAssertNil(archivedConversation.archivedAt)
        XCTAssertFalse(archivedConversation.hidden)
    }

    func testCreateNewMessage_sameGmThreadIdBackfillsMissingParticipantHashAndReusesConversation() async throws {
        let threadId = "thread-backfill-participant-hash"
        let existingConversation = ConversationBuilder()
            .withSnippet("Old snippet")
            .withLastMessageDate(Date(timeIntervalSince1970: 1_700_150_000))
            .build(in: context)

        _ = MessageBuilder()
            .withId("seed-backfill-message")
            .withThreadId(threadId)
            .inConversation(existingConversation)
            .build(in: context)

        var headers = ProcessedHeaders()
        headers.subject = "Re: Existing thread"
        headers.from = "Sender <sender@example.com>"
        headers.to = [EmailAddress(email: "recipient@example.com", displayName: nil)]
        headers.isFromMe = false

        let processedMessage = ProcessedMessage(
            id: "backfill-participant-hash-message",
            gmThreadId: threadId,
            snippet: "Latest snippet",
            cleanedSnippet: "Latest snippet",
            internalDate: Date(timeIntervalSince1970: 1_700_150_120),
            headers: headers,
            htmlBody: nil,
            plainTextBody: "Latest snippet",
            labelIds: ["INBOX"],
            isUnread: false,
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

        let fetch = Message.fetchRequest()
        fetch.predicate = NSPredicate(format: "id == %@", "backfill-participant-hash-message")
        fetch.fetchLimit = 1
        let savedMessage = try XCTUnwrap(context.fetch(fetch).first)

        XCTAssertEqual(savedMessage.conversation?.objectID, existingConversation.objectID)
        XCTAssertEqual(
            existingConversation.participantHash,
            calculateParticipantHash(from: ["sender@example.com"])
        )
    }

    func testCreateNewMessage_sentOnlyMessageInParticipantFallback_reactivatesConversation() async throws {
        let participantHash = calculateParticipantHash(from: [normalizedEmail("friend@example.com")])
        let archivedConversation = ConversationBuilder()
            .withParticipantHash(participantHash)
            .withSnippet("Old archived snippet")
            .withLastMessageDate(Date(timeIntervalSince1970: 1_700_200_000))
            .archived()
            .setHidden()
            .build(in: context)

        try testStack.saveViewContext()

        var headers = ProcessedHeaders()
        headers.subject = "New outbound"
        headers.from = "Me <me@example.com>"
        headers.to = [EmailAddress(email: "friend@example.com", displayName: nil)]
        headers.isFromMe = true

        let processedMessage = ProcessedMessage(
            id: "sent-only-fallback-message",
            gmThreadId: "thread-without-local-match",
            snippet: "Outbound from another client",
            cleanedSnippet: "Outbound from another client",
            internalDate: Date(timeIntervalSince1970: 1_700_200_120),
            headers: headers,
            htmlBody: nil,
            plainTextBody: "Outbound from another client",
            labelIds: ["SENT"],
            isUnread: false,
            isNewsletter: false,
            hasAttachments: false,
            attachmentInfo: []
        )

        try await persister.createNewMessage(
            processedMessage,
            labelIds: nil,
            myAliases: [normalizedEmail("me@example.com")],
            in: context
        )

        XCTAssertNil(archivedConversation.archivedAt)
        XCTAssertFalse(archivedConversation.hidden)

        let fetch = Message.fetchRequest()
        fetch.predicate = NSPredicate(format: "id == %@", "sent-only-fallback-message")
        fetch.fetchLimit = 1
        let savedMessage = try XCTUnwrap(context.fetch(fetch).first)
        XCTAssertEqual(savedMessage.conversation?.objectID, archivedConversation.objectID)
    }

    func testCreateNewMessage_sentOnlyMessageWithParticipantDrift_reusesExistingThreadConversation() async throws {
        let threadId = "thread-sent-participant-drift"
        let archivedConversation = ConversationBuilder()
            .withParticipantHash(calculateParticipantHash(from: ["friend@example.com"]))
            .withSnippet("Archived snippet")
            .withLastMessageDate(Date(timeIntervalSince1970: 1_700_210_000))
            .archived()
            .setHidden()
            .build(in: context)

        _ = MessageBuilder()
            .withId("seed-thread-message")
            .withThreadId(threadId)
            .inConversation(archivedConversation)
            .build(in: context)

        try testStack.saveViewContext()

        var headers = ProcessedHeaders()
        headers.subject = "Re: Archived thread"
        headers.from = "Me <me@example.com>"
        headers.to = [
            EmailAddress(email: "friend@example.com", displayName: nil),
            EmailAddress(email: "assistant@example.com", displayName: nil)
        ]
        headers.isFromMe = true

        let processedMessage = ProcessedMessage(
            id: "sent-participant-drift-message",
            gmThreadId: threadId,
            snippet: "Outbound from another client",
            cleanedSnippet: "Outbound from another client",
            internalDate: Date(timeIntervalSince1970: 1_700_210_120),
            headers: headers,
            htmlBody: nil,
            plainTextBody: "Outbound from another client",
            labelIds: ["SENT"],
            isUnread: false,
            isNewsletter: false,
            hasAttachments: false,
            attachmentInfo: []
        )

        try await persister.createNewMessage(
            processedMessage,
            labelIds: nil,
            myAliases: [normalizedEmail("me@example.com")],
            in: context
        )

        let conversationCount = try context.count(for: Conversation.fetchRequest())
        XCTAssertEqual(conversationCount, 1, "Sent-only sync should not spawn a new active conversation for the same Gmail thread")
        XCTAssertNil(archivedConversation.archivedAt)
        XCTAssertFalse(archivedConversation.hidden)

        let fetch = Message.fetchRequest()
        fetch.predicate = NSPredicate(format: "id == %@", "sent-participant-drift-message")
        fetch.fetchLimit = 1
        let savedMessage = try XCTUnwrap(context.fetch(fetch).first)
        XCTAssertEqual(savedMessage.conversation?.objectID, archivedConversation.objectID)
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

    func testUpdateExistingMessage_preservesPendingLocalMailboxStateWhileRefreshingCanonicalMetadata() async throws {
        let inboxLabel = LabelBuilder.inboxLabel(in: context)
        let unreadLabel = LabelBuilder.unreadLabel(in: context)

        let conversation = ConversationBuilder()
            .withSnippet("Local snippet")
            .withLastMessageDate(Date(timeIntervalSince1970: 1_700_300_000))
            .withUnreadCount(1)
            .hasInboxMessages(true)
            .visible()
            .build(in: context)
        let existingMessage = MessageBuilder()
            .withId("pending-local-state-message")
            .withThreadId("old-thread-id")
            .withSubject("Old subject")
            .withSender(email: "old@example.com", name: "Old Sender")
            .withSnippet("Local snippet")
            .inConversation(conversation)
            .build(in: context)
        existingMessage.addToLabels(inboxLabel)
        existingMessage.addToLabels(unreadLabel)
        existingMessage.isUnread = true
        existingMessage.isFromMe = false
        existingMessage.localModifiedAt = Date()

        var headers = ProcessedHeaders()
        headers.subject = "Updated subject"
        headers.from = "Me <me@example.com>"
        headers.to = [EmailAddress(email: "friend@example.com", displayName: nil)]
        headers.isFromMe = true
        headers.messageId = "<server-message-id@example.com>"
        headers.references = ["<ref-1@example.com>", "<ref-2@example.com>"]

        let processedMessage = ProcessedMessage(
            id: existingMessage.id,
            gmThreadId: "new-thread-id",
            snippet: "Server snippet",
            cleanedSnippet: "Server snippet",
            internalDate: existingMessage.internalDate,
            headers: headers,
            htmlBody: nil,
            plainTextBody: "Updated body",
            labelIds: ["SENT"],
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
        XCTAssertTrue(existingMessage.isUnread, "Pending local read/unread changes should win over server state")
        XCTAssertTrue(existingMessage.labels?.contains(where: { $0.id == "INBOX" }) ?? false)
        XCTAssertEqual(existingMessage.gmThreadId, "new-thread-id")
        XCTAssertEqual(existingMessage.subject, "Updated subject")
        XCTAssertTrue(existingMessage.isFromMe)
        XCTAssertEqual(existingMessage.messageIdValue, "<server-message-id@example.com>")
        XCTAssertEqual(existingMessage.referencesValue, "<ref-1@example.com> <ref-2@example.com>")
        XCTAssertEqual(existingMessage.senderEmailValue, "me@example.com")
        XCTAssertEqual(existingMessage.senderNameValue, "Me")
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

    func testUpdateExistingMessage_removesDuplicateInlineAttachmentsSharingContentID() async {
        let conversation = ConversationBuilder.simple(in: context)
        let existingMessage = MessageBuilder()
            .withId("message-inline-cid-dedup")
            .inConversation(conversation)
            .withAttachments()
            .build(in: context)
        existingMessage.hasAttachments = true

        let downloadedDuplicate = AttachmentBuilder()
            .withId("dup-inline-downloaded")
            .withFilename("IMG_6161.jpeg")
            .withMimeType("image/jpeg")
            .withContentId("6AFCA8C9-D2EF-4407-BD15-8D9F042220E9")
            .withLocalURL("Attachments/dup-inline-downloaded.jpg")
            .withPreviewURL("Previews/dup-inline-downloaded.jpg")
            .withByteSize(350_000)
            .downloaded()
            .forMessage(existingMessage)
            .build(in: context)

        let _ = AttachmentBuilder()
            .withId("dup-inline-queued-1")
            .withFilename("IMG_6161.jpeg")
            .withMimeType("image/jpeg")
            .withContentId("6AFCA8C9-D2EF-4407-BD15-8D9F042220E9")
            .withByteSize(350_000)
            .queued()
            .forMessage(existingMessage)
            .build(in: context)

        let _ = AttachmentBuilder()
            .withId("dup-inline-queued-2")
            .withFilename("IMG_6161.jpeg")
            .withMimeType("image/jpeg")
            .withContentId("6AFCA8C9-D2EF-4407-BD15-8D9F042220E9")
            .withByteSize(350_000)
            .queued()
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
            attachmentInfo: []
        )

        let didUpdate = await persister.updateExistingMessage(
            processedMessage,
            labelIds: nil,
            in: context
        )

        XCTAssertTrue(didUpdate)
        XCTAssertEqual(existingMessage.attachmentsArray.count, 1)
        XCTAssertEqual(existingMessage.attachmentsArray.first?.id, downloadedDuplicate.id)
        XCTAssertEqual(existingMessage.attachmentsArray.first?.localURL, "Attachments/dup-inline-downloaded.jpg")
    }

    func testUpdateExistingMessage_reconcilesOptimisticLocalRegularAttachmentWithoutDuplication() async throws {
        let conversation = ConversationBuilder.simple(in: context)
        let existingMessage = MessageBuilder()
            .withId("message-regular-attachment-merge")
            .inConversation(conversation)
            .withAttachments()
            .build(in: context)

        let optimisticAttachment = AttachmentBuilder()
            .withId("local_photo_attachment")
            .withFilename("photo.jpg")
            .withMimeType("image/jpeg")
            .withByteSize(2_048)
            .withLocalURL("Attachments/local_photo_attachment.jpg")
            .withPreviewURL("Previews/local_photo_attachment.jpg")
            .forMessage(existingMessage)
            .build(in: context)
        optimisticAttachment.state = .uploaded

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
                AttachmentInfo(
                    id: "real_attachment_1",
                    filename: "photo.jpg",
                    mimeType: "image/jpeg",
                    size: 2_048,
                    contentId: nil
                )
            ]
        )

        let didUpdate = await persister.updateExistingMessage(
            processedMessage,
            labelIds: nil,
            in: context
        )

        XCTAssertTrue(didUpdate)
        XCTAssertEqual(existingMessage.attachmentsArray.count, 1)

        let savedAttachment = try XCTUnwrap(existingMessage.attachmentsArray.first)
        XCTAssertEqual(savedAttachment.id, "real_attachment_1")
        XCTAssertEqual(savedAttachment.localURL, "Attachments/local_photo_attachment.jpg")
        XCTAssertEqual(savedAttachment.previewURL, "Previews/local_photo_attachment.jpg")
        XCTAssertEqual(savedAttachment.state, .uploaded)
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

    private func addConversationParticipant(person: Person, to conversation: Conversation) {
        let participant = ConversationParticipant(context: context)
        participant.id = UUID()
        participant.participantRole = .normal
        participant.person = person
        participant.conversation = conversation
    }

    private func addMessageParticipant(person: Person, kind: ParticipantKind, to message: Message) {
        let participant = MessageParticipant(context: context)
        participant.id = UUID()
        participant.participantKind = kind
        participant.person = person
        participant.message = message
    }
}

private final class StubMessageProcessor: MessageProcessor {
    private let processedMessage: ProcessedMessage?

    init(processedMessage: ProcessedMessage?) {
        self.processedMessage = processedMessage
    }

    override func processGmailMessage(_ gmailMessage: GmailMessage, myAliases: Set<String>) async -> ProcessedMessage? {
        processedMessage
    }
}

private final class HTMLSaveSpy {
    private let lock = NSLock()
    private var callCount = 0

    var recordedCallCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return callCount
    }

    func save(_ html: String, messageId: String) -> URL? {
        lock.lock()
        callCount += 1
        lock.unlock()
        return URL(fileURLWithPath: "/tmp/\(messageId).html")
    }
}
