import XCTest
@testable import esc_chatmail

@MainActor
final class ChatViewModelTests: XCTestCase {
    private func makeTestAuthSession(userEmail: String? = nil) -> AuthSession {
        let authSession = AuthSession(
            tokenManagerProvider: { MockTokenManager() },
            keychainService: MockKeychainService(),
            userDefaults: UserDefaults(suiteName: "ChatViewModelTests.\(UUID().uuidString)")!,
            clearConversationCaches: {},
            cleanupDownloads: {},
            resetCoreDataStore: {},
            clearAttachmentCache: {}
        )
        authSession.userEmail = userEmail
        return authSession
    }

    private func makeDependencies(authSession: AuthSession) -> Dependencies {
        let tokenManager = MockTokenManager()
        return Dependencies(
            authSession: authSession,
            tokenManager: tokenManager,
            gmailAPIClient: GmailAPIClient(tokenManager: tokenManager)
        )
    }

    func testOpenFullMessage_setsPresentedMessage() {
        let deps = makeDependencies(authSession: makeTestAuthSession(userEmail: "me@example.com"))
        let context = deps.viewContext
        let conversation = ConversationBuilder()
            .withDisplayName("Test Chat")
            .visible()
            .recentlyActive()
            .build(in: context)
        let message = MessageBuilder()
            .withId("message-1")
            .withSubject("Spring Sale")
            .withSender(email: "sender@example.com", name: "Sender")
            .inConversation(conversation)
            .build(in: context)

        let viewModel = ChatViewModel(conversation: conversation, deps: deps)

        viewModel.openFullMessage(message)

        XCTAssertTrue(viewModel.messageToViewInFull === message)
    }

    func testDismissFullMessage_clearsPresentedMessage() {
        let deps = makeDependencies(authSession: makeTestAuthSession(userEmail: "me@example.com"))
        let context = deps.viewContext
        let conversation = ConversationBuilder()
            .withDisplayName("Test Chat")
            .visible()
            .recentlyActive()
            .build(in: context)
        let message = MessageBuilder()
            .withId("message-2")
            .withSubject("Original Message")
            .withSender(email: "sender@example.com", name: "Sender")
            .inConversation(conversation)
            .build(in: context)

        let viewModel = ChatViewModel(conversation: conversation, deps: deps)
        viewModel.openFullMessage(message)

        viewModel.dismissFullMessage()

        XCTAssertNil(viewModel.messageToViewInFull)
    }

    func testSetMessageToForward_buildsForwardComposeContext() {
        let deps = makeDependencies(authSession: makeTestAuthSession(userEmail: "me@example.com"))
        let context = deps.viewContext
        let conversation = ConversationBuilder()
            .withDisplayName("Test Chat")
            .visible()
            .recentlyActive()
            .build(in: context)

        let me = Person(context: context)
        me.id = UUID()
        me.email = "me@example.com"
        me.displayName = "Me"

        let other = Person(context: context)
        other.id = UUID()
        other.email = "friend@example.com"
        other.displayName = "Friend"

        let meParticipant = ConversationParticipant(context: context)
        meParticipant.id = UUID()
        meParticipant.participantRole = .normal
        meParticipant.person = me
        meParticipant.conversation = conversation

        let otherParticipant = ConversationParticipant(context: context)
        otherParticipant.id = UUID()
        otherParticipant.participantRole = .normal
        otherParticipant.person = other
        otherParticipant.conversation = conversation

        let message = MessageBuilder()
            .withId("message-forward")
            .withSubject("Forward Me")
            .withSender(email: "friend@example.com", name: "Friend")
            .withBody("Original forward body")
            .inConversation(conversation)
            .build(in: context)

        let viewModel = ChatViewModel(conversation: conversation, deps: deps)

        viewModel.setMessageToForward(message)

        XCTAssertEqual(viewModel.forwardComposeContext?.id, "message-forward")
        XCTAssertEqual(viewModel.forwardComposeContext?.initialSubject, "Fwd: Forward Me")
        XCTAssertEqual(viewModel.forwardComposeContext?.forwardedInlineAttachmentInfos.count, 0)
    }

    func testSendReply_buildsReplySnapshotsAtViewModelEdge() async {
        let authSession = makeTestAuthSession(userEmail: "me@example.com")
        let coordinator = MockChatOutboundMessageCoordinator()
        let tokenManager = MockTokenManager()
        let deps = Dependencies(
            authSession: authSession,
            tokenManager: tokenManager,
            gmailAPIClient: GmailAPIClient(tokenManager: tokenManager),
            outboundMessageCoordinator: coordinator
        )
        let context = deps.viewContext
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

        let replyTarget = MessageBuilder()
            .withId("message-1")
            .withThreadId("thread-123")
            .withSubject("Original Subject")
            .withSender(email: "friend@example.com", name: "Friend")
            .withBody("Original body")
            .inConversation(conversation)
            .build(in: context)
        replyTarget.messageId = "<message-1@example.com>"
        replyTarget.references = "<older@example.com>"

        let viewModel = ChatViewModel(conversation: conversation, deps: deps)
        viewModel.replyText = "Reply body"
        viewModel.replyingTo = replyTarget

        await viewModel.sendReply(with: [])

        guard case .reply(let request)? = coordinator.lastRequest else {
            return XCTFail("Expected reply request")
        }
        XCTAssertEqual(request.context.metadata.recipientEmails, ["friend@example.com"])
        XCTAssertEqual(request.context.metadata.subject, "Re: Original Subject")
        XCTAssertEqual(request.context.metadata.threadId, "thread-123")
        XCTAssertEqual(request.context.metadata.inReplyTo, "<message-1@example.com>")
        XCTAssertEqual(request.context.metadata.references, ["<older@example.com>", "<message-1@example.com>"])
        XCTAssertEqual(
            request.context.optimisticConversation?.existingConversationObjectURI,
            conversation.objectID.uriRepresentation().absoluteString
        )
        XCTAssertEqual(request.body, "Reply body")
        XCTAssertEqual(viewModel.replyText, "")
        XCTAssertNil(viewModel.replyingTo)
    }
}

@MainActor
private final class MockChatOutboundMessageCoordinator: OutboundMessageCoordinating {
    private(set) var lastRequest: OutboundMessageRequest?

    func send(
        _ request: OutboundMessageRequest,
        reconciliationHooks: OutboundMessageReconciliationHooks
    ) async throws -> OutboundMessageResult? {
        lastRequest = request
        return .init(
            optimisticMessageID: "optimistic-1",
            conversationObjectURI: "x-coredata://conversation/123"
        )
    }
}
