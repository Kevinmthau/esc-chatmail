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

    func testSetMessageToForward_buildsForwardSnapshotsAtViewModelEdge() {
        let deps = makeDependencies(authSession: makeTestAuthSession(userEmail: "me@example.com"))
        let context = deps.viewContext
        AttachmentPaths.setupDirectories()
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

        let viewModel = ChatViewModel(conversation: conversation, deps: deps)

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
        _ = deps.htmlContentHandler.saveHTML(
            "<html><body><p>Original <strong>HTML</strong></p></body></html>",
            for: replyTarget.id
        )

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
            request.context.optimisticConversation?.existingConversationReference,
            ConversationReference(objectID: conversation.objectID)
        )
        XCTAssertEqual(request.body, "Reply body")
        XCTAssertTrue(request.context.metadata.originalMessage?.originalHTML?.contains("Original <strong>HTML</strong>") == true)
        XCTAssertEqual(viewModel.replyText, "")
        XCTAssertNil(viewModel.replyingTo)
    }

    func testSendReply_usesCapturedReplyTargetSnapshotAfterSelection() async {
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
        viewModel.replyingTo = replyTarget
        viewModel.replyText = "Reply body"

        replyTarget.subject = "Mutated Subject"
        replyTarget.messageId = "<mutated@example.com>"
        replyTarget.references = "<mutated-ref@example.com>"
        replyTarget.bodyText = "Mutated body"

        await viewModel.sendReply(with: [])

        guard case .reply(let request)? = coordinator.lastRequest else {
            return XCTFail("Expected reply request")
        }
        XCTAssertEqual(request.context.metadata.subject, "Re: Original Subject")
        XCTAssertEqual(request.context.metadata.inReplyTo, "<message-1@example.com>")
        XCTAssertEqual(request.context.metadata.references, ["<older@example.com>", "<message-1@example.com>"])
        XCTAssertEqual(request.context.metadata.originalMessage?.body, "Original body")
    }

    func testSendReply_loadsOriginalHTMLLazilyAtSendTime() async {
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
            .withId("message-lazy-html")
            .withThreadId("thread-123")
            .withSubject("Original Subject")
            .withSender(email: "friend@example.com", name: "Friend")
            .withBody("Original body")
            .inConversation(conversation)
            .build(in: context)
        replyTarget.messageId = "<message-1@example.com>"
        replyTarget.references = "<older@example.com>"
        _ = deps.htmlContentHandler.saveHTML(
            "<html><body><p>Initial HTML</p></body></html>",
            for: replyTarget.id
        )

        let viewModel = ChatViewModel(conversation: conversation, deps: deps)
        viewModel.replyingTo = replyTarget
        viewModel.replyText = "Reply body"

        _ = deps.htmlContentHandler.saveHTML(
            "<html><body><p>Updated HTML</p></body></html>",
            for: replyTarget.id
        )

        await viewModel.sendReply(with: [])

        guard case .reply(let request)? = coordinator.lastRequest else {
            return XCTFail("Expected reply request")
        }
        XCTAssertTrue(request.context.metadata.originalMessage?.originalHTML?.contains("Updated HTML") == true)
        XCTAssertFalse(request.context.metadata.originalMessage?.originalHTML?.contains("Initial HTML") == true)
    }

    func testSendReply_doesNotCaptureOriginalHTMLWhenOriginalDisplayWouldFallbackToPlainText() async {
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
        friend.email = "alerts@cnb.com"
        friend.displayName = "City National Bank"

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
            .withId("message-degraded-html")
            .withThreadId("thread-123")
            .withSubject("Zelle payment alert")
            .withSender(email: "alerts@cnb.com", name: "City National Bank")
            .withBody("""
            City National Bank / Zelle payment alert

            Andrew Archer sent you $100.00.
            Date
            Apr 8, 2026
            Status
            Completed

            Review this payment in your banking app:
            https://example.com/open
            """)
            .inConversation(conversation)
            .build(in: context)
        replyTarget.messageId = "<message-degraded-html@example.com>"
        _ = deps.htmlContentHandler.saveHTML(
            """
            <!DOCTYPE html>
            <html>
            <head>
              <style>
                .actionButton table { display: none; }
                body { margin: 0; padding: 0; background: #ffffff; }
                table { border-collapse: collapse; }
              </style>
            </head>
            <body>
              <table width="100%"><tr><td align="center"><img src="https://example.com/logo.png" alt="City National Bank" width="180"></td></tr></table>
              <table width="100%"><tr><td height="72">&nbsp;</td></tr></table>
              <table width="100%"><tr><td height="96">&nbsp;</td></tr></table>
              <table width="100%"><tr><td align="center"><img src="https://example.com/zelle.png" alt="Zelle" width="110"></td></tr></table>
              <table width="100%"><tr><td style="font-size:14px; line-height:22px;">A payment notification is available in your secure inbox.</td></tr></table>
              <table class="actionButton" width="100%"><tr><td><a href="https://example.com/open">View Payment</a></td></tr></table>
              <table width="100%"><tr><td height="84">&nbsp;</td></tr></table>
              <table width="100%"><tr><td style="font-size:11px; line-height:18px; color:#666666;">Privacy Policy | Security Center | Do not reply to this email.</td></tr></table>
            </body>
            </html>
            """,
            for: replyTarget.id
        )

        let viewModel = ChatViewModel(conversation: conversation, deps: deps)
        viewModel.replyingTo = replyTarget
        viewModel.replyText = "Reply body"

        await viewModel.sendReply(with: [])

        guard case .reply(let request)? = coordinator.lastRequest else {
            return XCTFail("Expected reply request")
        }
        XCTAssertNil(request.context.metadata.originalMessage?.originalHTML)
        XCTAssertTrue(request.context.metadata.originalMessage?.body?.contains("Andrew Archer sent you $100.00.") == true)
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
            conversationReference: ConversationReference(
                persistentStoreURI: URL(string: "x-coredata://conversation/123")!
            )
        )
    }
}
