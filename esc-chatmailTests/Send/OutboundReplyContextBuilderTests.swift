import XCTest
@testable import esc_chatmail

@MainActor
final class OutboundReplyContextBuilderTests: XCTestCase {
    private var coreDataStack: TestCoreDataStack!

    override func setUp() {
        super.setUp()
        coreDataStack = TestCoreDataStack()
    }

    override func tearDown() {
        coreDataStack = nil
        super.tearDown()
    }

    func testBuild_replyingToMessageExtractsReplyMetadataAndConversationAnchor() {
        let authSession = makeTestAuthSession(userEmail: "me@example.com")
        let builder = OutboundReplyContextBuilder(
            replyMetadataBuilder: ReplyMetadataBuilder(authSession: authSession)
        )
        let context = coreDataStack.viewContext

        let conversation = ConversationBuilder()
            .withDisplayName("Reply Thread")
            .visible()
            .recentlyActive()
            .build(in: context)

        let me = Person(context: context)
        me.id = UUID()
        me.email = "me@example.com"

        let friend = Person(context: context)
        friend.id = UUID()
        friend.email = "friend@example.com"
        friend.displayName = "Friend"

        let meParticipant = ConversationParticipant(context: context)
        meParticipant.id = UUID()
        meParticipant.person = me
        meParticipant.participantRole = .normal
        meParticipant.conversation = conversation

        let friendParticipant = ConversationParticipant(context: context)
        friendParticipant.id = UUID()
        friendParticipant.person = friend
        friendParticipant.participantRole = .normal
        friendParticipant.conversation = conversation

        let replyingTo = MessageBuilder()
            .withId("message-1")
            .withThreadId("thread-123")
            .withSubject("Original Subject")
            .withSender(email: "friend@example.com", name: "Friend")
            .withBody("Original body")
            .inConversation(conversation)
            .build(in: context)
        replyingTo.messageId = "<message-1@example.com>"
        replyingTo.references = "<older@example.com>"

        let replyContext = builder.build(
            conversation: conversation,
            replyingTo: replyingTo
        )

        XCTAssertEqual(replyContext.recipientEmails, ["friend@example.com"])
        XCTAssertEqual(replyContext.subject, "Re: Original Subject")
        XCTAssertEqual(replyContext.threadId, "thread-123")
        XCTAssertEqual(replyContext.inReplyTo, "<message-1@example.com>")
        XCTAssertEqual(replyContext.references, ["<older@example.com>", "<message-1@example.com>"])
        XCTAssertEqual(replyContext.originalMessage?.senderName, "Friend")
        XCTAssertEqual(replyContext.originalMessage?.senderEmail, "friend@example.com")
        XCTAssertEqual(replyContext.originalMessage?.body, "Original body")
        XCTAssertEqual(
            replyContext.existingConversation?.objectURI,
            conversation.objectID.uriRepresentation().absoluteString
        )
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
