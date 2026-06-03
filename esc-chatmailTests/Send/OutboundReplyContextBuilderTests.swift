import XCTest
import CoreData
@testable import esc_chatmail

@MainActor
final class OutboundReplyContextBuilderTests: XCTestCase {
    private var coreDataStack: TestCoreDataStack!
    private var htmlContentHandler: HTMLContentHandler!

    override func setUp() {
        super.setUp()
        coreDataStack = TestCoreDataStack()
        htmlContentHandler = HTMLContentHandler()
    }

    override func tearDown() {
        htmlContentHandler = nil
        coreDataStack = nil
        super.tearDown()
    }

    func testBuild_createsStableReplyRequestContextAndConversationAnchor() throws {
        let context = coreDataStack.viewContext
        let conversation = ConversationBuilder()
            .visible()
            .recentlyActive()
            .build(in: context)
        let replyingTo = MessageBuilder()
            .withId("message-1")
            .inConversation(conversation)
            .build(in: context)
        try context.obtainPermanentIDs(for: [conversation, replyingTo])
        let builder = makeBuilder()
        let conversationReference = ConversationReference(objectID: conversation.objectID)

        let replyContext = builder.build(
            conversationObjectID: conversation.objectID,
            replyingToMessageObjectID: replyingTo.objectID,
            optimisticConversation: .existingConversation(conversationReference)
        )

        XCTAssertEqual(replyContext.conversationObjectID, conversation.objectID)
        XCTAssertEqual(replyContext.replyingToMessageObjectID, replyingTo.objectID)
        XCTAssertEqual(replyContext.optimisticConversation?.existingConversationReference, conversationReference)
    }

    func testBuildReplyMetadata_readsReplyMetadataFromManagedObjects() throws {
        let context = coreDataStack.viewContext
        let conversation = makeReplyConversation(in: context, friendEmail: "friend@example.com")
        let replyingTo = MessageBuilder()
            .withId("message-1")
            .withThreadId("thread-123")
            .withSubject("Original Subject")
            .withSender(email: "friend@example.com", name: "Friend")
            .withBody("Original body")
            .inConversation(conversation)
            .build(in: context)
        try context.obtainPermanentIDs(for: [conversation, replyingTo])
        replyingTo.messageId = "<message-1@example.com>"
        replyingTo.references = "<older@example.com>"
        _ = htmlContentHandler.saveHTML(
            "<html><body><p>Original <strong>HTML</strong></p></body></html>",
            for: replyingTo.id
        )

        let metadata = try makeBuilder().buildReplyMetadata(
            .init(
                conversationObjectID: conversation.objectID,
                replyingToMessageObjectID: replyingTo.objectID,
                optimisticConversation: .existingConversation(
                    ConversationReference(objectID: conversation.objectID)
                )
            )
        )

        XCTAssertEqual(metadata.recipientEmails, ["friend@example.com"])
        XCTAssertEqual(metadata.subject, "Re: Original Subject")
        XCTAssertEqual(metadata.threadId, "thread-123")
        XCTAssertEqual(metadata.inReplyTo, "<message-1@example.com>")
        XCTAssertEqual(metadata.references, ["<older@example.com>", "<message-1@example.com>"])
        XCTAssertEqual(metadata.originalMessage?.senderName, "Friend")
        XCTAssertEqual(metadata.originalMessage?.senderEmail, "friend@example.com")
        XCTAssertEqual(metadata.originalMessage?.body, "Original body")
        XCTAssertTrue(metadata.originalMessage?.originalHTML?.contains("Original <strong>HTML</strong>") == true)
    }

    func testBuildReplyMetadata_usesCurrentManagedObjectValuesAfterRequestCreation() throws {
        let context = coreDataStack.viewContext
        let conversation = makeReplyConversation(in: context, friendEmail: "before@example.com")
        let replyingTo = MessageBuilder()
            .withId("message-1")
            .withThreadId("thread-before")
            .withSubject("Before Subject")
            .withSender(email: "before@example.com", name: "Before Friend")
            .withBody("Before body")
            .inConversation(conversation)
            .build(in: context)
        try context.obtainPermanentIDs(for: [conversation, replyingTo])
        replyingTo.messageId = "<before@example.com>"
        replyingTo.references = "<ref-before@example.com>"
        _ = htmlContentHandler.saveHTML(
            "<html><body><p>Before HTML</p></body></html>",
            for: replyingTo.id
        )

        let replyContext = makeBuilder().build(
            conversationObjectID: conversation.objectID,
            replyingToMessageObjectID: replyingTo.objectID,
            optimisticConversation: .existingConversation(
                ConversationReference(objectID: conversation.objectID)
            )
        )

        let updatedFriend = try XCTUnwrap(
            Array(conversation.participants ?? [])
                .compactMap(\.person)
                .first { $0.email == "before@example.com" }
        )
        updatedFriend.email = "after@example.com"
        updatedFriend.displayName = "After Friend"
        replyingTo.gmThreadId = "thread-after"
        replyingTo.subject = "After Subject"
        replyingTo.messageId = "<after@example.com>"
        replyingTo.references = "<ref-after@example.com>"
        replyingTo.bodyText = "After body"
        replyingTo.senderName = "After Friend"
        replyingTo.senderEmail = "after@example.com"
        _ = htmlContentHandler.saveHTML(
            "<html><body><p>After HTML</p></body></html>",
            for: replyingTo.id
        )

        let metadata = try makeBuilder().buildReplyMetadata(replyContext)

        XCTAssertEqual(metadata.recipientEmails, ["after@example.com"])
        XCTAssertEqual(metadata.subject, "Re: After Subject")
        XCTAssertEqual(metadata.threadId, "thread-after")
        XCTAssertEqual(metadata.inReplyTo, "<after@example.com>")
        XCTAssertEqual(metadata.references, ["<ref-after@example.com>", "<after@example.com>"])
        XCTAssertEqual(metadata.originalMessage?.senderName, "After Friend")
        XCTAssertEqual(metadata.originalMessage?.senderEmail, "after@example.com")
        XCTAssertEqual(metadata.originalMessage?.body, "After body")
        XCTAssertTrue(metadata.originalMessage?.originalHTML?.contains("After HTML") == true)
        XCTAssertFalse(metadata.originalMessage?.originalHTML?.contains("Before HTML") == true)
    }

    private func makeBuilder(userEmail: String = "me@example.com") -> OutboundReplyContextBuilder {
        OutboundReplyContextBuilder(
            viewContext: coreDataStack.viewContext,
            replyMetadataBuilder: ReplyMetadataBuilder(
                authSession: makeTestAuthSession(userEmail: userEmail)
            ),
            replyHTMLContentLoader: HTMLContentLoader(
                contentHandler: htmlContentHandler,
                sanitizer: .shared
            )
        )
    }

    private func makeReplyConversation(
        in context: NSManagedObjectContext,
        friendEmail: String
    ) -> Conversation {
        let conversation = ConversationBuilder()
            .withDisplayName("Reply Thread")
            .visible()
            .recentlyActive()
            .build(in: context)

        let me = PersonBuilder()
            .withEmail("me@example.com")
            .noDisplayName()
            .build(in: context)

        let friend = PersonBuilder()
            .withEmail(friendEmail)
            .withDisplayName("Friend")
            .build(in: context)

        let meParticipant = context.insertTestObject(ConversationParticipant.self)
        meParticipant.id = UUID()
        meParticipant.person = me
        meParticipant.participantRole = .normal
        meParticipant.conversation = conversation

        let friendParticipant = context.insertTestObject(ConversationParticipant.self)
        friendParticipant.id = UUID()
        friendParticipant.person = friend
        friendParticipant.participantRole = .normal
        friendParticipant.conversation = conversation

        return conversation
    }

    private func makeTestAuthSession(userEmail: String? = nil) -> AuthSession {
        let authSession = AuthSession(
            tokenManagerProvider: { MockTokenManager() },
            keychainService: MockKeychainService(),
            userDefaults: UserDefaults(suiteName: "OutboundReplyContextBuilderTests.\(UUID().uuidString)")!,
            clearConversationCaches: {},
            cleanupDownloads: {},
            resetCoreDataStore: {},
            clearAttachmentCache: {}
        )
        authSession.userEmail = userEmail
        return authSession
    }
}
