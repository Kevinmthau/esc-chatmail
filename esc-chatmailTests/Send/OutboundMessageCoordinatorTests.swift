import XCTest
import CoreData
@testable import esc_chatmail

@MainActor
final class OutboundMessageCoordinatorTests: XCTestCase {
    private var coreDataStack: TestCoreDataStack!

    override func setUp() {
        super.setUp()
        coreDataStack = TestCoreDataStack()
    }

    override func tearDown() {
        coreDataStack = nil
        super.tearDown()
    }

    func testSend_composeNormalizesInputAndRunsSendNew() async throws {
        let sendService = MockOutboundMessageSendService(context: coreDataStack.viewContext)
        let syncPerformer = MockCoordinatorSyncPerformer()
        let coordinator = makeCoordinator(sendService: sendService, syncPerformer: syncPerformer)

        let submission = try await coordinator.send(
            .compose(
                .init(
                    recipientEmails: ["to@example.com"],
                    subject: "",
                    body: "  Hello world  ",
                    attachments: []
                )
            )
        )

        let queuedSubmission = try XCTUnwrap(submission)
        await queuedSubmission.backgroundTask.value

        let snapshot = sendService.snapshot
        XCTAssertEqual(snapshot.createOptimisticCalls.count, 1)
        XCTAssertEqual(snapshot.createOptimisticCalls.first?.recipients, ["to@example.com"])
        XCTAssertEqual(snapshot.createOptimisticCalls.first?.body, "Hello world")
        XCTAssertNil(snapshot.createOptimisticCalls.first?.subject)
        XCTAssertEqual(snapshot.sendNewCalls.count, 1)
        XCTAssertEqual(snapshot.sendNewCalls.first?.body, "Hello world")
        XCTAssertNil(snapshot.sendNewCalls.first?.subject)
        XCTAssertEqual(snapshot.sendReplyCalls.count, 0)
        XCTAssertNotNil(queuedSubmission.conversationObjectID)
        XCTAssertEqual(syncPerformer.performIncrementalSyncCalls, 1)
    }

    func testSend_replyBuildsReplyMetadataAndRunsSendReply() async throws {
        let authSession = makeTestAuthSession(userEmail: "me@example.com")
        let sendService = MockOutboundMessageSendService(context: coreDataStack.viewContext)
        let syncPerformer = MockCoordinatorSyncPerformer()
        let coordinator = makeCoordinator(
            sendService: sendService,
            syncPerformer: syncPerformer,
            authSession: authSession
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

        let submission = try await coordinator.send(
            .reply(
                .init(
                    conversation: conversation,
                    replyingTo: replyingTo,
                    body: " Reply body ",
                    attachments: []
                )
            )
        )

        let queuedSubmission = try XCTUnwrap(submission)
        await queuedSubmission.backgroundTask.value

        let snapshot = sendService.snapshot
        XCTAssertEqual(snapshot.createOptimisticCalls.count, 1)
        XCTAssertEqual(snapshot.createOptimisticCalls.first?.recipients, ["friend@example.com"])
        XCTAssertEqual(snapshot.createOptimisticCalls.first?.body, "Reply body")
        XCTAssertEqual(snapshot.createOptimisticCalls.first?.subject, "Re: Original Subject")
        XCTAssertEqual(snapshot.createOptimisticCalls.first?.threadId, "thread-123")
        XCTAssertEqual(snapshot.createOptimisticCalls.first?.existingConversationObjectID, conversation.objectID)
        XCTAssertEqual(snapshot.sendNewCalls.count, 0)
        XCTAssertEqual(snapshot.sendReplyCalls.count, 1)
        XCTAssertEqual(snapshot.sendReplyCalls.first?.recipients, ["friend@example.com"])
        XCTAssertEqual(snapshot.sendReplyCalls.first?.body, "Reply body")
        XCTAssertEqual(snapshot.sendReplyCalls.first?.subject, "Re: Original Subject")
        XCTAssertEqual(snapshot.sendReplyCalls.first?.threadId, "thread-123")
        XCTAssertEqual(snapshot.sendReplyCalls.first?.inReplyTo, "<message-1@example.com>")
        XCTAssertEqual(snapshot.sendReplyCalls.first?.references, ["<older@example.com>", "<message-1@example.com>"])
        XCTAssertEqual(syncPerformer.performIncrementalSyncCalls, 1)
    }

    func testSend_forwardBuildsCombinedBodiesAndRunsSendNew() async throws {
        let sendService = MockOutboundMessageSendService(context: coreDataStack.viewContext)
        let syncPerformer = MockCoordinatorSyncPerformer()
        let coordinator = makeCoordinator(sendService: sendService, syncPerformer: syncPerformer)

        let submission = try await coordinator.send(
            .forward(
                .init(
                    recipientEmails: ["to@example.com"],
                    subject: "Fwd: Hello",
                    body: "  Intro line  ",
                    attachments: [],
                    forwardedPlainTextBody: "Forwarded plain text",
                    forwardedHTMLBody: "<html><body><p>Forwarded HTML</p></body></html>",
                    forwardedInlineAttachments: []
                )
            )
        )

        let queuedSubmission = try XCTUnwrap(submission)
        await queuedSubmission.backgroundTask.value

        let snapshot = sendService.snapshot
        XCTAssertEqual(snapshot.createOptimisticCalls.count, 1)
        XCTAssertEqual(snapshot.createOptimisticCalls.first?.body, "Intro line\n\nForwarded plain text")
        XCTAssertEqual(snapshot.sendNewCalls.count, 1)
        XCTAssertEqual(snapshot.sendNewCalls.first?.body, "Intro line\n\nForwarded plain text")
        XCTAssertEqual(snapshot.sendNewCalls.first?.subject, "Fwd: Hello")
        XCTAssertTrue(snapshot.sendNewCalls.first?.htmlBody?.contains("Intro line") == true)
        XCTAssertTrue(snapshot.sendNewCalls.first?.htmlBody?.contains("Forwarded HTML") == true)
        XCTAssertEqual(syncPerformer.performIncrementalSyncCalls, 1)
    }

    private func makeCoordinator(
        sendService: MockOutboundMessageSendService,
        syncPerformer: MockCoordinatorSyncPerformer,
        authSession: AuthSession? = nil
    ) -> OutboundMessageCoordinator {
        let resolvedAuthSession = authSession ?? makeTestAuthSession(userEmail: "me@example.com")
        return OutboundMessageCoordinator(
            sendService: sendService,
            syncPerformer: syncPerformer,
            replyMetadataBuilder: ReplyMetadataBuilder(authSession: resolvedAuthSession),
            messageFormatBuilder: MessageFormatBuilder(authSession: resolvedAuthSession)
        )
    }

    private func makeTestAuthSession(userEmail: String? = nil) -> AuthSession {
        let authSession = AuthSession(
            tokenManagerProvider: { MockTokenManager() },
            keychainService: MockKeychainService(),
            userDefaults: UserDefaults(suiteName: "OutboundMessageCoordinatorTests.\(UUID().uuidString)")!,
            clearConversationCaches: {},
            cleanupDownloads: {},
            resetCoreDataStore: {},
            clearAttachmentCache: {}
        )
        authSession.userEmail = userEmail
        return authSession
    }
}

@MainActor
private final class MockCoordinatorSyncPerformer: IncrementalSyncPerforming {
    private(set) var performIncrementalSyncCalls = 0

    func performIncrementalSync() async throws {
        performIncrementalSyncCalls += 1
    }
}

private final class MockOutboundMessageSendService: OutboundMessageSendServicing {
    struct CreateOptimisticCall {
        let recipients: [String]
        let body: String
        let subject: String?
        let threadId: String?
        let existingConversationObjectID: NSManagedObjectID?
    }

    struct SendNewCall {
        let recipients: [String]
        let body: String
        let htmlBody: String?
        let subject: String?
    }

    struct SendReplyCall {
        let recipients: [String]
        let body: String
        let subject: String
        let threadId: String
        let inReplyTo: String?
        let references: [String]
    }

    struct Snapshot {
        let createOptimisticCalls: [CreateOptimisticCall]
        let sendNewCalls: [SendNewCall]
        let sendReplyCalls: [SendReplyCall]
    }

    private let context: NSManagedObjectContext
    private let queue = DispatchQueue(label: "OutboundMessageCoordinatorTests.MockSendService")
    private var optimisticMessages: [String: Message] = [:]
    private var createCalls: [CreateOptimisticCall] = []
    private var newCalls: [SendNewCall] = []
    private var replyCalls: [SendReplyCall] = []

    init(context: NSManagedObjectContext) {
        self.context = context
    }

    var snapshot: Snapshot {
        queue.sync {
            Snapshot(
                createOptimisticCalls: createCalls,
                sendNewCalls: newCalls,
                sendReplyCalls: replyCalls
            )
        }
    }

    @MainActor
    func createOptimisticMessage(
        to recipients: [String],
        body: String,
        subject: String?,
        threadId: String?,
        attachments: [Attachment],
        existingConversation: Conversation?
    ) async throws -> Message {
        queue.sync {
            createCalls.append(
                CreateOptimisticCall(
                    recipients: recipients,
                    body: body,
                    subject: subject,
                    threadId: threadId,
                    existingConversationObjectID: existingConversation?.objectID
                )
            )
        }

        let conversation = existingConversation ?? ConversationBuilder()
            .visible()
            .recentlyActive()
            .build(in: context)

        let message = Message(context: context)
        message.id = "optimistic-\(UUID().uuidString)"
        message.gmThreadId = threadId ?? ""
        message.subject = subject
        message.bodyText = body
        message.internalDate = Date()
        message.isFromMe = true
        message.conversation = conversation

        optimisticMessages[message.id] = message
        return message
    }

    func attachmentToInfo(_ attachment: Attachment) -> GmailSendService.AttachmentInfo {
        GmailSendService.AttachmentInfo(
            localURL: attachment.localURLValue,
            filename: attachment.filenameValue,
            mimeType: attachment.mimeTypeValue,
            contentId: attachment.contentId
        )
    }

    func sendReply(
        to recipients: [String],
        body: String,
        subject: String,
        threadId: String,
        inReplyTo: String?,
        references: [String],
        originalMessage: QuotedMessage?,
        attachmentInfos: [GmailSendService.AttachmentInfo]
    ) async throws -> GmailSendService.SendResult {
        queue.sync {
            replyCalls.append(
                SendReplyCall(
                    recipients: recipients,
                    body: body,
                    subject: subject,
                    threadId: threadId,
                    inReplyTo: inReplyTo,
                    references: references
                )
            )
        }

        return GmailSendService.SendResult(
            messageId: "sent-\(UUID().uuidString)",
            threadId: threadId
        )
    }

    func sendNew(
        to recipients: [String],
        body: String,
        htmlBody: String?,
        subject: String?,
        attachmentInfos: [GmailSendService.AttachmentInfo],
        inlineAttachmentInfos: [GmailSendService.AttachmentInfo]
    ) async throws -> GmailSendService.SendResult {
        queue.sync {
            newCalls.append(
                SendNewCall(
                    recipients: recipients,
                    body: body,
                    htmlBody: htmlBody,
                    subject: subject
                )
            )
        }

        return GmailSendService.SendResult(
            messageId: "sent-\(UUID().uuidString)",
            threadId: "thread-\(UUID().uuidString)"
        )
    }

    @MainActor
    func fetchMessageSync(byID messageID: String) -> Message? {
        optimisticMessages[messageID]
    }

    @MainActor
    func updateOptimisticMessage(_ message: Message, with result: GmailSendService.SendResult) {
        optimisticMessages[message.id] = nil
        message.id = result.messageId
        message.gmThreadId = result.threadId
        optimisticMessages[result.messageId] = message
    }

    @MainActor
    func markAttachmentsAsUploaded(_ attachments: [Attachment]) {}

    @MainActor
    func markAttachmentsAsFailed(_ attachments: [Attachment]) {}

    @MainActor
    func handleFailedOptimisticMessage(byID messageID: String, fallbackAttachments: [Attachment]) {
        optimisticMessages[messageID] = nil
    }
}
