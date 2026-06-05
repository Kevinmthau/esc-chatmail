import CoreData
import CoreGraphics
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

    @discardableResult
    private func addConversationParticipant(
        person: Person,
        to conversation: Conversation,
        in context: NSManagedObjectContext
    ) -> ConversationParticipant {
        let participant = context.insertTestObject(ConversationParticipant.self)
        participant.id = UUID()
        participant.participantRole = .normal
        participant.person = person
        participant.conversation = conversation
        return participant
    }

    func testOpenFullMessage_setsPresentedSession() {
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

        let viewModel = ChatViewModel(
            conversation: conversation,
            chatDependencies: deps.makeChatDependencies()
        )

        viewModel.openFullMessage(message)

        XCTAssertTrue(viewModel.fullEmailOpenSession?.message === message)
        XCTAssertEqual(viewModel.fullEmailOpenSession?.messageObjectID, message.objectID)
        XCTAssertTrue(viewModel.fullEmailOpenSession?.hasImmediateVisualSurface == true)
    }

    func testOpenFullMessage_payloadHitPresentsPreparedHTMLWithoutFallbackPrewarm() {
        let deps = makeDependencies(authSession: makeTestAuthSession(userEmail: "me@example.com"))
        let context = deps.viewContext
        let conversation = ConversationBuilder()
            .withDisplayName("Test Chat")
            .visible()
            .recentlyActive()
            .build(in: context)
        let message = MessageBuilder()
            .withId("message-prepared")
            .withSubject("Prepared")
            .withSender(email: "sender@example.com", name: "Sender")
            .withBody("Prepared body")
            .inConversation(conversation)
            .build(in: context)
        let payload = FullEmailOpenPayload(
            messageId: "message-prepared",
            sourceSignature: "sha256:prepared",
            html: "<html><body>Prepared full email</body></html>",
            presentation: .html,
            sourceKind: .html,
            sourceLocation: .messageFile,
            hasHTMLSource: true,
            checkoutAvailability: .ready
        )
        let opener = MockFullEmailOpener(preparedPayload: payload)

        let viewModel = ChatViewModel(
            conversation: conversation,
            chatDependencies: deps.makeChatDependencies(fullEmailOpener: opener)
        )

        viewModel.openFullMessage(message)

        XCTAssertTrue(viewModel.fullEmailOpenSession?.message === message)
        XCTAssertEqual(viewModel.fullEmailOpenSession?.initialOpenPayload, payload)
        XCTAssertEqual(
            viewModel.fullEmailOpenSession?.readerState,
            .preparedHTML(payload, placeholder: FullEmailPlaceholder(message: message))
        )
        XCTAssertEqual(opener.preparedPayloadRequests.count, 1)
        XCTAssertEqual(opener.prepaintRequests.count, 1)
        XCTAssertEqual(opener.prepaintRequests.first?.request.messageId, "message-prepared")
        XCTAssertEqual(opener.prepaintRequests.first?.message.id, "message-prepared")
        XCTAssertEqual(opener.prepaintRequests.first?.payload, payload)
        XCTAssertTrue(opener.prewarmedMessages.isEmpty)
    }

    func testOpenFullMessage_payloadMissPresentsMessageAndStartsFallbackPrewarm() {
        let deps = makeDependencies(authSession: makeTestAuthSession(userEmail: "me@example.com"))
        let context = deps.viewContext
        let conversation = ConversationBuilder()
            .withDisplayName("Test Chat")
            .visible()
            .recentlyActive()
            .build(in: context)
        let message = MessageBuilder()
            .withId("message-miss")
            .withSubject("Miss")
            .withSender(email: "sender@example.com", name: "Sender")
            .withBody("Miss body")
            .inConversation(conversation)
            .build(in: context)
        let opener = MockFullEmailOpener(preparedPayload: nil)

        let viewModel = ChatViewModel(
            conversation: conversation,
            chatDependencies: deps.makeChatDependencies(fullEmailOpener: opener)
        )

        viewModel.openFullMessage(message)

        XCTAssertTrue(viewModel.fullEmailOpenSession?.message === message)
        XCTAssertNil(viewModel.fullEmailOpenSession?.initialOpenPayload)
        XCTAssertEqual(
            viewModel.fullEmailOpenSession?.readerState,
            .loading(FullEmailPlaceholder(message: message))
        )
        XCTAssertEqual(viewModel.fullEmailOpenSession?.immediatePlaceholder.subject, "Miss")
        XCTAssertTrue(viewModel.fullEmailOpenSession?.hasImmediateVisualSurface == true)
        XCTAssertEqual(opener.preparedPayloadRequests.count, 1)
        XCTAssertTrue(opener.prepaintRequests.isEmpty)
        XCTAssertEqual(opener.prewarmedMessages.map(\.id), ["message-miss"])
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

        let viewModel = ChatViewModel(
            conversation: conversation,
            chatDependencies: deps.makeChatDependencies()
        )
        viewModel.openFullMessage(message)

        viewModel.dismissFullMessage()

        XCTAssertNil(viewModel.fullEmailOpenSession)
    }

    func testSetMessageToForward_buildsForwardSnapshotsAtViewModelEdge() {
        let deps = makeDependencies(authSession: makeTestAuthSession(userEmail: "me@example.com"))
        let context = deps.viewContext
        AttachmentPaths.setupDirectories()
        let conversation = ConversationBuilder()
            .withDisplayName("Test Chat")
            .visible()
            .recentlyActive()
            .build(in: context)

        let me = PersonBuilder()
            .withEmail("me@example.com")
            .withDisplayName("Me")
            .build(in: context)

        let other = PersonBuilder()
            .withEmail("friend@example.com")
            .withDisplayName("Friend")
            .build(in: context)

        addConversationParticipant(person: me, to: conversation, in: context)
        addConversationParticipant(person: other, to: conversation, in: context)

        let message = MessageBuilder()
            .withId("message-forward")
            .withSubject("Forward Me")
            .withSender(email: "friend@example.com", name: "Friend")
            .withBody("Original forward body")
            .inConversation(conversation)
            .build(in: context)
        _ = deps.htmlContentHandler.saveHTML(
            "<html><body><p>Forwarded HTML body</p></body></html>",
            for: message.id
        )

        let regularPath = AttachmentPaths.originalPath(idOrUUID: "forward-regular", ext: "pdf")
        XCTAssertTrue(AttachmentPaths.saveData(Data("regular".utf8), to: regularPath))
        defer { AttachmentPaths.deleteFile(at: regularPath) }

        let inlinePath = AttachmentPaths.originalPath(idOrUUID: "forward-inline", ext: "png")
        XCTAssertTrue(AttachmentPaths.saveData(Data("inline".utf8), to: inlinePath))
        defer { AttachmentPaths.deleteFile(at: inlinePath) }

        let _ = AttachmentBuilder()
            .withId("attachment-regular-1")
            .withFilename("report.pdf")
            .withMimeType("application/pdf")
            .withByteSize(91_248)
            .withLocalURL(regularPath)
            .downloaded()
            .forMessage(message)
            .build(in: context)
        let _ = AttachmentBuilder()
            .withId("attachment-regular-2")
            .withFilename("report.pdf")
            .withMimeType("application/pdf")
            .withByteSize(91_248)
            .withLocalURL(regularPath)
            .downloaded()
            .forMessage(message)
            .build(in: context)
        let _ = AttachmentBuilder()
            .withId("attachment-inline")
            .withFilename("inline.png")
            .withMimeType("image/png")
            .withLocalURL(inlinePath)
            .withContentId("cid-inline")
            .downloaded()
            .forMessage(message)
            .build(in: context)

        let viewModel = ChatViewModel(
            conversation: conversation,
            chatDependencies: deps.makeChatDependencies()
        )

        viewModel.setMessageToForward(message)

        XCTAssertEqual(viewModel.forwardComposeContext?.id, "message-forward")
        XCTAssertEqual(viewModel.forwardComposeContext?.initialSubject, "Fwd: Forward Me")
        XCTAssertTrue(viewModel.forwardComposeContext?.forwardedPlainTextBody.contains("Original forward body") == true)
        XCTAssertTrue(viewModel.forwardComposeContext?.forwardedHTMLBody?.contains("Forwarded HTML body") == true)
        XCTAssertEqual(viewModel.forwardComposeContext?.forwardedInlineAttachmentInfos.count, 1)
        XCTAssertEqual(viewModel.forwardComposeContext?.forwardedInlineAttachmentInfos.first?.contentId, "cid-inline")
        XCTAssertEqual(viewModel.forwardComposeContext?.forwardedRegularAttachments.count, 1)
        XCTAssertEqual(viewModel.forwardComposeContext?.forwardedRegularAttachments.first?.filename, "report.pdf")
    }

    func testSendReply_buildsStableReplyRequestAtViewModelEdge() async {
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

        let me = PersonBuilder()
            .withEmail("me@example.com")
            .noDisplayName()
            .build(in: context)

        let friend = PersonBuilder()
            .withEmail("friend@example.com")
            .withDisplayName("Friend")
            .build(in: context)

        addConversationParticipant(person: me, to: conversation, in: context)
        addConversationParticipant(person: friend, to: conversation, in: context)

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
        _ = deps.htmlContentHandler.saveHTML(
            "<html><body><p>Original <strong>HTML</strong></p></body></html>",
            for: replyTarget.id
        )

        let viewModel = ChatViewModel(
            conversation: conversation,
            chatDependencies: deps.makeChatDependencies()
        )
        viewModel.replyText = "Reply body"
        viewModel.replyingTo = replyTarget

        let didSend = await viewModel.sendReply(with: [])

        guard case .reply(let request)? = coordinator.lastRequest else {
            return XCTFail("Expected reply request")
        }
        XCTAssertTrue(didSend)
        XCTAssertEqual(request.context.conversationObjectID, conversation.objectID)
        XCTAssertEqual(request.context.replyingToMessageObjectID, replyTarget.objectID)
        XCTAssertEqual(
            request.context.optimisticConversation?.existingConversationReference,
            ConversationReference(objectID: conversation.objectID)
        )
        XCTAssertEqual(request.body, "Reply body")
        XCTAssertEqual(viewModel.replyText, "")
        XCTAssertNil(viewModel.replyingTo)
    }

    func testSendReply_usesStableReplyTargetIdentifierAfterSelection() async {
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

        let me = PersonBuilder()
            .withEmail("me@example.com")
            .noDisplayName()
            .build(in: context)

        let friend = PersonBuilder()
            .withEmail("friend@example.com")
            .withDisplayName("Friend")
            .build(in: context)

        addConversationParticipant(person: me, to: conversation, in: context)
        addConversationParticipant(person: friend, to: conversation, in: context)

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

        let viewModel = ChatViewModel(
            conversation: conversation,
            chatDependencies: deps.makeChatDependencies()
        )
        viewModel.replyingTo = replyTarget
        viewModel.replyText = "Reply body"

        replyTarget.subject = "Mutated Subject"
        replyTarget.messageId = "<mutated@example.com>"
        replyTarget.references = "<mutated-ref@example.com>"
        replyTarget.bodyText = "Mutated body"

        let didSend = await viewModel.sendReply(with: [])

        guard case .reply(let request)? = coordinator.lastRequest else {
            return XCTFail("Expected reply request")
        }
        XCTAssertTrue(didSend)
        XCTAssertEqual(request.context.conversationObjectID, conversation.objectID)
        XCTAssertEqual(request.context.replyingToMessageObjectID, replyTarget.objectID)
    }

    func testSendReply_reportsFailureWithoutClearingDraftState() async {
        let authSession = makeTestAuthSession(userEmail: "me@example.com")
        let coordinator = MockChatOutboundMessageCoordinator()
        coordinator.sendError = MockChatSendError.optimisticCreationFailed
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

        let viewModel = ChatViewModel(
            conversation: conversation,
            chatDependencies: deps.makeChatDependencies()
        )
        viewModel.replyText = "Retryable reply"

        let didSend = await viewModel.sendReply(with: [])

        XCTAssertFalse(didSend)
        XCTAssertEqual(viewModel.replyText, "Retryable reply")
    }
}

@MainActor
private final class MockFullEmailOpener: FullEmailOpening {
    struct PreparedPayloadRequest {
        let request: OriginalEmailWarmRequest
        let message: Message?
        let width: CGFloat
    }

    struct PrepaintRequest {
        let request: OriginalEmailWarmRequest
        let message: Message
        let payload: FullEmailOpenPayload
        let width: CGFloat
    }

    let preparedPayload: FullEmailOpenPayload?
    private(set) var preparedPayloadRequests: [PreparedPayloadRequest] = []
    private(set) var prepaintRequests: [PrepaintRequest] = []
    private(set) var prewarmedMessages: [Message] = []

    init(preparedPayload: FullEmailOpenPayload?) {
        self.preparedPayload = preparedPayload
    }

    func preparedOpenPayload(
        request: OriginalEmailWarmRequest,
        message: Message?,
        width: CGFloat
    ) -> FullEmailOpenPayload? {
        preparedPayloadRequests.append(
            PreparedPayloadRequest(
                request: request,
                message: message,
                width: width
            )
        )
        return preparedPayload
    }

    func prepaintAfterExplicitOpen(
        request: OriginalEmailWarmRequest,
        message: Message,
        payload: FullEmailOpenPayload,
        width: CGFloat
    ) {
        prepaintRequests.append(
            PrepaintRequest(
                request: request,
                message: message,
                payload: payload,
                width: width
            )
        )
    }

    func prewarmOnOpen(message: Message) {
        prewarmedMessages.append(message)
    }
}

@MainActor
private final class MockChatOutboundMessageCoordinator: OutboundMessageCoordinating {
    private(set) var lastRequest: OutboundMessageRequest?
    var sendError: Error?
    var sendResult: OutboundMessageResult? = .init(
        optimisticMessageID: "optimistic-1",
        conversationReference: ConversationReference(
            persistentStoreURI: URL(string: "x-coredata://conversation/123")!
        )
    )

    func send(
        _ request: OutboundMessageRequest,
        reconciliationHooks: OutboundMessageReconciliationHooks
    ) async throws -> OutboundMessageResult? {
        lastRequest = request
        if let sendError {
            throw sendError
        }
        return sendResult
    }
}

private enum MockChatSendError: Error {
    case optimisticCreationFailed
}
