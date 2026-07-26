import CoreData
import Combine
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

    func testComposerChangesPublishOnlyComposerState() {
        let deps = makeDependencies(
            authSession: makeTestAuthSession(userEmail: "me@example.com")
        )
        let context = deps.viewContext
        let conversation = ConversationBuilder()
            .withDisplayName("Reply Thread")
            .visible()
            .recentlyActive()
            .build(in: context)
        let replyTarget = MessageBuilder()
            .withId("reply-target")
            .inConversation(conversation)
            .build(in: context)
        let viewModel = ChatViewModel(
            conversation: conversation,
            chatDependencies: deps.makeChatDependencies()
        )
        var composerChangeCount = 0
        var viewModelChangeCount = 0
        let composerCancellable = viewModel.composerState.objectWillChange.sink {
            composerChangeCount += 1
        }
        let viewModelCancellable = viewModel.objectWillChange.sink {
            viewModelChangeCount += 1
        }

        viewModel.replyText = "Draft reply"
        viewModel.replyingTo = replyTarget

        XCTAssertEqual(composerChangeCount, 2)
        XCTAssertEqual(viewModelChangeCount, 0)
        XCTAssertEqual(viewModel.composerState.replyText, "Draft reply")
        XCTAssertEqual(viewModel.composerState.replyingTo, replyTarget)

        viewModel.resolvedDisplayName = "Friend"

        XCTAssertEqual(composerChangeCount, 2)
        XCTAssertEqual(viewModelChangeCount, 1)
        withExtendedLifetime((composerCancellable, viewModelCancellable)) {}
    }

    func testBackgroundReadLeavesLaterUnreadCountDurableForBlueDot() async throws {
        let stack = TestCoreDataStack(automaticallyMergesChanges: true)
        let context = stack.viewContext
        let pendingActionsManager = MockPendingActionsManager()
        let messageActions = MessageActions(
            coreDataStack: stack,
            pendingActionsManager: pendingActionsManager
        )
        let baseDependencies = makeDependencies(
            authSession: makeTestAuthSession(userEmail: "me@example.com")
        ).makeChatDependencies()
        let chatDependencies = ChatDependencies(
            session: baseDependencies.session,
            content: baseDependencies.content,
            messaging: ChatMessagingDependencies(
                messageActions: messageActions,
                outboundMessageCoordinator: baseDependencies.messaging.outboundMessageCoordinator,
                outboundAttachmentContextBuilder: baseDependencies.messaging.outboundAttachmentContextBuilder,
                outboundReplyContextBuilder: baseDependencies.messaging.outboundReplyContextBuilder,
                composeForwardModeContextBuilder: baseDependencies.messaging.composeForwardModeContextBuilder
            ),
            contacts: baseDependencies.contacts,
            storage: ChatStorageDependencies(
                viewContext: context,
                makeBackgroundContext: { stack.newBackgroundContext() }
            ),
            fullEmailOpener: baseDependencies.fullEmailOpener
        )

        let conversation = ConversationBuilder()
            .visible()
            .withUnreadCount(1)
            .build(in: context)
        let inboxLabel = LabelBuilder().inbox().build(in: context)
        let initialMessage = MessageBuilder()
            .withId("initial-unread")
            .unread()
            .inConversation(conversation)
            .build(in: context)
        initialMessage.addToLabels(inboxLabel)
        try stack.saveViewContext()

        let viewModel = ChatViewModel(
            conversation: conversation,
            chatDependencies: chatDependencies
        )
        let initialUnreadSnapshot = messageActions.snapshotUnreadInboxMessageObjectIDs(
            conversationID: conversation.id
        )

        let laterMessage = MessageBuilder()
            .withId("later-unread")
            .unread()
            .inConversation(conversation)
            .build(in: context)
        laterMessage.addToLabels(inboxLabel)
        conversation.inboxUnreadCount = 2
        try stack.saveViewContext()

        viewModel.markConversationAsRead(messageObjectIDs: initialUnreadSnapshot)
        await waitUntil {
            await pendingActionsManager.pendingActionCount() == 1
        }

        PendingActionBuilder()
            .markAsRead()
            .forMessage("pending-action-activity")
            .build(in: context)
        try stack.saveViewContext()

        let verificationContext = stack.newBackgroundContext()
        let conversationObjectID = conversation.objectID
        let durableUnreadCount = await verificationContext.perform {
            let durableConversation = try? verificationContext.existingObject(
                with: conversationObjectID
            ) as? Conversation
            return durableConversation?.inboxUnreadCount
        }
        XCTAssertEqual(durableUnreadCount, 1)

        context.refreshAllObjects()
        XCTAssertFalse(initialMessage.isUnread)
        XCTAssertTrue(laterMessage.isUnread)
        XCTAssertEqual(ConversationSnapshot(from: conversation).inboxUnreadCount, 1)
    }

    func testOpenEmailReaderFromBubbleAccessoryCreatesReaderRoute() throws {
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

        viewModel.openEmailReader(
            for: message.objectID,
            source: .bubbleAccessory,
            initialMode: .original
        )

        let route = try XCTUnwrap(viewModel.emailReaderRoute)
        XCTAssertEqual(route.messageObjectID, message.objectID)
        XCTAssertEqual(route.conversationObjectID, conversation.objectID)
        XCTAssertEqual(route.source, .bubbleAccessory)
        XCTAssertEqual(route.initialMode, .original)
    }

    func testOpenEmailReaderFromContextMenuCreatesReaderRoute() throws {
        let deps = makeDependencies(authSession: makeTestAuthSession(userEmail: "me@example.com"))
        let context = deps.viewContext
        let conversation = ConversationBuilder()
            .withDisplayName("Test Chat")
            .visible()
            .recentlyActive()
            .build(in: context)
        let message = MessageBuilder()
            .withId("message-context-menu")
            .withSubject("Context Menu")
            .withSender(email: "sender@example.com", name: "Sender")
            .inConversation(conversation)
            .build(in: context)

        let viewModel = ChatViewModel(
            conversation: conversation,
            chatDependencies: deps.makeChatDependencies()
        )

        viewModel.openEmailReader(
            for: message.objectID,
            source: .contextMenu,
            initialMode: .original
        )

        let route = try XCTUnwrap(viewModel.emailReaderRoute)
        XCTAssertEqual(route.messageObjectID, message.objectID)
        XCTAssertEqual(route.source, .contextMenu)
    }

    func testOpenEmailReaderFromPreviewCardCreatesReaderRoute() throws {
        let deps = makeDependencies(authSession: makeTestAuthSession(userEmail: "me@example.com"))
        let context = deps.viewContext
        let conversation = ConversationBuilder()
            .withDisplayName("Test Chat")
            .visible()
            .recentlyActive()
            .build(in: context)
        let message = MessageBuilder()
            .withId("message-preview-card")
            .withSubject("Preview Card")
            .withSender(email: "sender@example.com", name: "Sender")
            .inConversation(conversation)
            .build(in: context)

        let viewModel = ChatViewModel(
            conversation: conversation,
            chatDependencies: deps.makeChatDependencies()
        )

        viewModel.openEmailReader(
            for: message.objectID,
            source: .previewCard,
            initialMode: .original
        )

        let route = try XCTUnwrap(viewModel.emailReaderRoute)
        XCTAssertEqual(route.messageObjectID, message.objectID)
        XCTAssertEqual(route.source, .previewCard)
    }

    func testDismissDestination_clearsEmailReaderRoute() {
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
        viewModel.openEmailReader(
            for: message.objectID,
            source: .bubbleAccessory,
            initialMode: .original
        )

        viewModel.dismissDestination()

        XCTAssertNil(viewModel.destination)
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
        guard case .forwardCompose(let context) = viewModel.destination else {
            return XCTFail("Expected forward compose destination")
        }
        XCTAssertEqual(context.id, "message-forward")
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

    private func waitUntil(
        timeout: TimeInterval = 2.0,
        pollIntervalNanoseconds: UInt64 = 20_000_000,
        file: StaticString = #filePath,
        line: UInt = #line,
        condition: @escaping () async -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)

        while Date() < deadline {
            if await condition() {
                return
            }
            try? await Task.sleep(nanoseconds: pollIntervalNanoseconds)
        }

        XCTFail("Timed out waiting for condition", file: file, line: line)
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
