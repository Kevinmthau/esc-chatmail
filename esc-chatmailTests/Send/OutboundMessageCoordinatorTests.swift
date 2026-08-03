import XCTest
import CoreData
@testable import esc_chatmail

@MainActor
final class OutboundMessageCoordinatorTests: XCTestCase {
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

    func testSend_composeNormalizesInputAndRunsSendNew() async throws {
        let sendService = MockOutboundMessageSendService(context: coreDataStack.viewContext)
        let syncPerformer = MockCoordinatorSyncPerformer()
        let mutationTracker = MockOutboundSendMutationTracker()
        let coordinator = makeCoordinator(
            sendService: sendService,
            syncPerformer: syncPerformer,
            mutationTracker: mutationTracker
        )
        let completionExpectation = expectation(description: "compose send completes")

        let submission = try await coordinator.send(
            .compose(
                .init(
                    recipientEmails: ["to@example.com"],
                    subject: "",
                    body: "  Hello world  ",
                    attachments: [],
                    optimisticConversation: .participantHash("participant-hash-1")
                )
            ),
            reconciliationHooks: .init(
                onSuccess: { _ in completionExpectation.fulfill() },
                onFailure: nil
            )
        )

        let queuedSubmission = try XCTUnwrap(submission)
        await fulfillment(of: [completionExpectation], timeout: 1.0)

        let snapshot = sendService.snapshot
        XCTAssertEqual(snapshot.createOptimisticCalls.count, 1)
        XCTAssertEqual(snapshot.createOptimisticCalls.first?.recipients, ["to@example.com"])
        XCTAssertEqual(snapshot.createOptimisticCalls.first?.body, "Hello world")
        XCTAssertNil(snapshot.createOptimisticCalls.first?.subject)
        XCTAssertEqual(snapshot.createOptimisticCalls.first?.optimisticConversation?.participantHashValue, "participant-hash-1")
        XCTAssertEqual(snapshot.sendNewCalls.count, 1)
        XCTAssertEqual(snapshot.sendNewCalls.first?.body, "Hello world")
        XCTAssertNil(snapshot.sendNewCalls.first?.subject)
        XCTAssertEqual(snapshot.sendReplyCalls.count, 0)
        XCTAssertNotNil(queuedSubmission.conversationReference)
        XCTAssertEqual(
            queuedSubmission.optimisticMessageObjectID,
            snapshot.createdOptimisticMessageObjectIDs.last
        )
        XCTAssertEqual(syncPerformer.performIncrementalSyncCalls, 1)
        XCTAssertEqual(mutationTracker.pendingMutationIDs, [queuedSubmission.optimisticMessageID])
        XCTAssertEqual(mutationTracker.trackedConversationReferences, [queuedSubmission.conversationReference])
        XCTAssertEqual(mutationTracker.successfulMutationIDs, [queuedSubmission.optimisticMessageID])
    }

    func testSend_replyBuildsReplyMetadataAndRunsSendReply() async throws {
        let sendService = MockOutboundMessageSendService(context: coreDataStack.viewContext)
        let syncPerformer = MockCoordinatorSyncPerformer()
        let mutationTracker = MockOutboundSendMutationTracker()
        let coordinator = makeCoordinator(
            sendService: sendService,
            syncPerformer: syncPerformer,
            mutationTracker: mutationTracker
        )
        let completionExpectation = expectation(description: "reply send completes")

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

        let submission = try await coordinator.send(
            .reply(
                .init(
                    context: .init(
                        conversationObjectID: conversation.objectID,
                        replyingToMessageObjectID: replyingTo.objectID,
                        optimisticConversation: .existingConversation(
                            ConversationReference(objectID: conversation.objectID)
                        )
                    ),
                    body: " Reply body ",
                    attachments: []
                )
            ),
            reconciliationHooks: .init(
                onSuccess: { _ in completionExpectation.fulfill() },
                onFailure: nil
            )
        )

        let queuedSubmission = try XCTUnwrap(submission)
        await fulfillment(of: [completionExpectation], timeout: 1.0)

        let snapshot = sendService.snapshot
        XCTAssertEqual(snapshot.createOptimisticCalls.count, 1)
        XCTAssertEqual(snapshot.createOptimisticCalls.first?.recipients, ["friend@example.com"])
        XCTAssertEqual(snapshot.createOptimisticCalls.first?.body, "Reply body")
        XCTAssertEqual(snapshot.createOptimisticCalls.first?.subject, "Re: Original Subject")
        XCTAssertEqual(snapshot.createOptimisticCalls.first?.threadId, "thread-123")
        XCTAssertEqual(
            snapshot.createOptimisticCalls.first?.optimisticConversation?.existingConversationReference,
            ConversationReference(objectID: conversation.objectID)
        )
        XCTAssertEqual(snapshot.sendNewCalls.count, 0)
        XCTAssertEqual(snapshot.sendReplyCalls.count, 1)
        XCTAssertEqual(snapshot.sendReplyCalls.first?.recipients, ["friend@example.com"])
        XCTAssertEqual(snapshot.sendReplyCalls.first?.body, "Reply body")
        XCTAssertEqual(snapshot.sendReplyCalls.first?.subject, "Re: Original Subject")
        XCTAssertEqual(snapshot.sendReplyCalls.first?.threadId, "thread-123")
        XCTAssertEqual(snapshot.sendReplyCalls.first?.inReplyTo, "<message-1@example.com>")
        XCTAssertEqual(snapshot.sendReplyCalls.first?.references, ["<older@example.com>", "<message-1@example.com>"])
        XCTAssertEqual(snapshot.sendReplyCalls.first?.originalMessage?.senderEmail, "friend@example.com")
        XCTAssertEqual(snapshot.sendReplyCalls.first?.originalMessage?.body, "Original body")
        XCTAssertTrue(snapshot.sendReplyCalls.first?.originalMessage?.originalHTML?.contains("Original <strong>HTML</strong>") == true)
        XCTAssertEqual(
            queuedSubmission.optimisticMessageObjectID,
            snapshot.createdOptimisticMessageObjectIDs.last
        )
        XCTAssertEqual(syncPerformer.performIncrementalSyncCalls, 1)
        XCTAssertEqual(mutationTracker.pendingMutationIDs, [queuedSubmission.optimisticMessageID])
        XCTAssertEqual(mutationTracker.trackedConversationReferences, [queuedSubmission.conversationReference])
        XCTAssertEqual(mutationTracker.successfulMutationIDs, [queuedSubmission.optimisticMessageID])
    }

    func testSend_replyUsesLatestConversationAndMessageValuesAfterRequestCreation() async throws {
        let sendService = MockOutboundMessageSendService(context: coreDataStack.viewContext)
        let syncPerformer = MockCoordinatorSyncPerformer()
        let coordinator = makeCoordinator(sendService: sendService, syncPerformer: syncPerformer)
        let completionExpectation = expectation(description: "reply send completes")

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

        let request = OutboundMessageRequest.reply(
            .init(
                context: .init(
                    conversationObjectID: conversation.objectID,
                    replyingToMessageObjectID: replyingTo.objectID,
                    optimisticConversation: .existingConversation(
                        ConversationReference(objectID: conversation.objectID)
                    )
                ),
                body: " Reply body ",
                attachments: []
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

        let submission = try await coordinator.send(
            request,
            reconciliationHooks: .init(
                onSuccess: { _ in completionExpectation.fulfill() },
                onFailure: nil
            )
        )

        let queuedSubmission = try XCTUnwrap(submission)
        await fulfillment(of: [completionExpectation], timeout: 1.0)

        let snapshot = sendService.snapshot
        XCTAssertEqual(snapshot.createOptimisticCalls.first?.recipients, ["after@example.com"])
        XCTAssertEqual(snapshot.createOptimisticCalls.first?.subject, "Re: After Subject")
        XCTAssertEqual(snapshot.createOptimisticCalls.first?.threadId, "thread-after")
        XCTAssertEqual(snapshot.sendReplyCalls.first?.recipients, ["after@example.com"])
        XCTAssertEqual(snapshot.sendReplyCalls.first?.subject, "Re: After Subject")
        XCTAssertEqual(snapshot.sendReplyCalls.first?.threadId, "thread-after")
        XCTAssertEqual(snapshot.sendReplyCalls.first?.inReplyTo, "<after@example.com>")
        XCTAssertEqual(snapshot.sendReplyCalls.first?.references, ["<ref-after@example.com>", "<after@example.com>"])
        XCTAssertEqual(snapshot.sendReplyCalls.first?.originalMessage?.senderName, "After Friend")
        XCTAssertEqual(snapshot.sendReplyCalls.first?.originalMessage?.senderEmail, "after@example.com")
        XCTAssertEqual(snapshot.sendReplyCalls.first?.originalMessage?.body, "After body")
        XCTAssertTrue(snapshot.sendReplyCalls.first?.originalMessage?.originalHTML?.contains("After HTML") == true)
        XCTAssertFalse(snapshot.sendReplyCalls.first?.originalMessage?.originalHTML?.contains("Before HTML") == true)
        XCTAssertEqual(snapshot.createOptimisticCalls.first?.optimisticConversation?.existingConversationReference, ConversationReference(objectID: conversation.objectID))
        XCTAssertEqual(queuedSubmission.conversationReference, ConversationReference(objectID: conversation.objectID))
    }

    func testSend_forwardBuildsCombinedBodiesUsesInlineSnapshotsAndRunsSendNew() async throws {
        let sendService = MockOutboundMessageSendService(context: coreDataStack.viewContext)
        let syncPerformer = MockCoordinatorSyncPerformer()
        let coordinator = makeCoordinator(sendService: sendService, syncPerformer: syncPerformer)
        let completionExpectation = expectation(description: "forward send completes")
        let attachmentBuilder = OutboundAttachmentContextBuilder(viewContext: coreDataStack.viewContext)
        let inlineAttachment = AttachmentBuilder()
            .withId("inline-attachment")
            .withFilename("inline.png")
            .withMimeType("image/png")
            .downloaded()
            .build(in: coreDataStack.viewContext)
        inlineAttachment.contentId = "cid-inline"

        let submission = try await coordinator.send(
            .forward(
                .init(
                    recipientEmails: ["to@example.com"],
                    subject: "Fwd: Hello",
                    body: "  Intro line  ",
                    attachments: [],
                    forwardedPlainTextBody: "Forwarded plain text",
                    forwardedHTMLBody: "<html><body><p>Forwarded HTML</p></body></html>",
                    forwardedInlineAttachmentInfos: try attachmentBuilder.buildInlineAttachmentInfos(
                        from: [inlineAttachment]
                    ),
                    optimisticConversation: .participantHash("participant-hash-2")
                )
            ),
            reconciliationHooks: .init(
                onSuccess: { _ in completionExpectation.fulfill() },
                onFailure: nil
            )
        )

        _ = try XCTUnwrap(submission)
        await fulfillment(of: [completionExpectation], timeout: 1.0)

        let snapshot = sendService.snapshot
        XCTAssertEqual(snapshot.createOptimisticCalls.count, 1)
        XCTAssertEqual(snapshot.createOptimisticCalls.first?.body, "Intro line\n\nForwarded plain text")
        XCTAssertEqual(snapshot.createOptimisticCalls.first?.chatPreviewText, "Intro line")
        XCTAssertEqual(snapshot.createOptimisticCalls.first?.optimisticConversation?.participantHashValue, "participant-hash-2")
        XCTAssertEqual(snapshot.sendNewCalls.count, 1)
        XCTAssertEqual(snapshot.sendNewCalls.first?.body, "Intro line\n\nForwarded plain text")
        XCTAssertEqual(snapshot.sendNewCalls.first?.subject, "Fwd: Hello")
        XCTAssertTrue(snapshot.sendNewCalls.first?.htmlBody?.contains("Intro line") == true)
        XCTAssertTrue(snapshot.sendNewCalls.first?.htmlBody?.contains("Forwarded HTML") == true)
        XCTAssertEqual(snapshot.markAttachmentsAsUploadingCalls, [])
        XCTAssertEqual(snapshot.sendNewCalls.first?.inlineAttachmentContentIDs, ["cid-inline"])
        XCTAssertEqual(syncPerformer.performIncrementalSyncCalls, 1)
    }

    func testSend_forwardWithoutUserBodyKeepsOptimisticPreviewEmptyAndSendsForwardedBody() async throws {
        let sendService = MockOutboundMessageSendService(context: coreDataStack.viewContext)
        let syncPerformer = MockCoordinatorSyncPerformer()
        let coordinator = makeCoordinator(sendService: sendService, syncPerformer: syncPerformer)
        let completionExpectation = expectation(description: "forward send completes")

        _ = try await coordinator.send(
            .forward(
                .init(
                    recipientEmails: ["to@example.com"],
                    subject: "Fwd: Hello",
                    body: "  \n  ",
                    attachments: [],
                    forwardedPlainTextBody: "Forwarded plain text",
                    forwardedHTMLBody: nil,
                    forwardedInlineAttachmentInfos: [],
                    optimisticConversation: .participantHash("participant-hash-3")
                )
            ),
            reconciliationHooks: .init(
                onSuccess: { _ in completionExpectation.fulfill() },
                onFailure: nil
            )
        )

        await fulfillment(of: [completionExpectation], timeout: 1.0)

        let snapshot = sendService.snapshot
        XCTAssertEqual(snapshot.createOptimisticCalls.count, 1)
        XCTAssertEqual(snapshot.createOptimisticCalls.first?.body, "Forwarded plain text")
        XCTAssertNil(snapshot.createOptimisticCalls.first?.chatPreviewText)
        XCTAssertEqual(snapshot.sendNewCalls.count, 1)
        XCTAssertEqual(snapshot.sendNewCalls.first?.body, "Forwarded plain text")
        XCTAssertTrue(snapshot.sendNewCalls.first?.htmlBody?.contains("Forwarded plain text") == true)
        XCTAssertEqual(syncPerformer.performIncrementalSyncCalls, 1)
    }

    func testSend_invokesSuccessHooksAfterBackgroundSend() async throws {
        let sendService = MockOutboundMessageSendService(context: coreDataStack.viewContext)
        let syncPerformer = MockCoordinatorSyncPerformer()
        let coordinator = makeCoordinator(sendService: sendService, syncPerformer: syncPerformer)

        let successExpectation = expectation(description: "success hook called")
        var successPayload: OutboundMessageReconciliationHooks.Success?

        let submission = try await coordinator.send(
            .compose(
                .init(
                    recipientEmails: ["to@example.com"],
                    subject: "Hello",
                    body: "Body",
                    attachments: []
                )
            ),
            reconciliationHooks: .init(
                onSuccess: { payload in
                    successPayload = payload
                    successExpectation.fulfill()
                },
                onFailure: nil
            )
        )

        XCTAssertNotNil(submission)
        await fulfillment(of: [successExpectation], timeout: 1.0)
        XCTAssertEqual(successPayload?.optimisticMessageID, submission?.optimisticMessageID)
        XCTAssertNotNil(successPayload?.sentMessageID)
        XCTAssertNotNil(successPayload?.threadID)
    }

    func testSend_backgroundFailureTracksFailedMutationAndInvokesFailureHook() async throws {
        let sendService = MockOutboundMessageSendService(context: coreDataStack.viewContext)
        sendService.sendNewError = GmailSendService.SendError.apiError("boom")
        let syncPerformer = MockCoordinatorSyncPerformer()
        let mutationTracker = MockOutboundSendMutationTracker()
        let coordinator = makeCoordinator(
            sendService: sendService,
            syncPerformer: syncPerformer,
            mutationTracker: mutationTracker
        )

        let failureExpectation = expectation(description: "failure hook called")
        var failurePayload: OutboundMessageReconciliationHooks.Failure?

        let submission = try await coordinator.send(
            .compose(
                .init(
                    recipientEmails: ["to@example.com"],
                    subject: "Hello",
                    body: "Body",
                    attachments: []
                )
            ),
            reconciliationHooks: .init(
                onSuccess: nil,
                onFailure: { payload in
                    failurePayload = payload
                    failureExpectation.fulfill()
                }
            )
        )

        let queuedSubmission = try XCTUnwrap(submission)
        await fulfillment(of: [failureExpectation], timeout: 1.0)
        XCTAssertEqual(failurePayload?.optimisticMessageID, queuedSubmission.optimisticMessageID)
        XCTAssertEqual(mutationTracker.pendingMutationIDs, [queuedSubmission.optimisticMessageID])
        XCTAssertEqual(mutationTracker.failedMutationIDs, [queuedSubmission.optimisticMessageID])
        XCTAssertEqual(syncPerformer.performIncrementalSyncCalls, 0)
    }

    private func makeCoordinator(
        sendService: MockOutboundMessageSendService,
        syncPerformer: MockCoordinatorSyncPerformer,
        authSession: AuthSession? = nil,
        mutationTracker: MockOutboundSendMutationTracker? = nil
    ) -> OutboundMessageCoordinator {
        let resolvedAuthSession = authSession ?? makeTestAuthSession(userEmail: "me@example.com")
        return OutboundMessageCoordinator(
            sendService: sendService,
            syncPerformer: syncPerformer,
            messageFormatBuilder: MessageFormatBuilder(authSession: resolvedAuthSession),
            outboundReplyContextBuilder: OutboundReplyContextBuilder(
                viewContext: coreDataStack.viewContext,
                replyMetadataBuilder: ReplyMetadataBuilder(authSession: resolvedAuthSession),
                replyHTMLContentLoader: HTMLContentLoader(
                    contentHandler: htmlContentHandler,
                    sanitizer: .shared
                )
            ),
            mutationTracker: mutationTracker ?? MockOutboundSendMutationTracker()
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
        let chatPreviewText: String?
        let optimisticConversation: OptimisticConversationReference?
        let attachmentReferences: [LocalAttachmentReference]
    }

    struct SendNewCall {
        let recipients: [String]
        let body: String
        let htmlBody: String?
        let subject: String?
        let inlineAttachmentContentIDs: [String]
    }

    struct SendReplyCall {
        let recipients: [String]
        let fromEmail: String?
        let fromName: String?
        let body: String
        let subject: String
        let threadId: String
        let inReplyTo: String?
        let references: [String]
        let originalMessage: QuotedMessage?
    }

    struct Snapshot {
        let createOptimisticCalls: [CreateOptimisticCall]
        let createdOptimisticMessageObjectIDs: [NSManagedObjectID]
        let sendNewCalls: [SendNewCall]
        let sendReplyCalls: [SendReplyCall]
        let markAttachmentsAsUploadingCalls: [[LocalAttachmentReference]]
    }

    private let context: NSManagedObjectContext
    private let queue = DispatchQueue(label: "OutboundMessageCoordinatorTests.MockSendService")
    private var optimisticMessages: [String: Message] = [:]
    private var remoteCommittedResults: [String: GmailSendService.SendResult] = [:]
    private var createCalls: [CreateOptimisticCall] = []
    private var createdOptimisticMessageObjectIDs: [NSManagedObjectID] = []
    private var newCalls: [SendNewCall] = []
    private var replyCalls: [SendReplyCall] = []
    private var markUploadingCalls: [[LocalAttachmentReference]] = []
    var sendDelayNanoseconds: UInt64 = 0
    var sendNewError: Error?
    var sendReplyError: Error?

    init(context: NSManagedObjectContext) {
        self.context = context
    }

    var snapshot: Snapshot {
        queue.sync {
            Snapshot(
                createOptimisticCalls: createCalls,
                createdOptimisticMessageObjectIDs: createdOptimisticMessageObjectIDs,
                sendNewCalls: newCalls,
                sendReplyCalls: replyCalls,
                markAttachmentsAsUploadingCalls: markUploadingCalls
            )
        }
    }

    @MainActor
    func createOptimisticMessage(
        to recipients: [String],
        body: String,
        subject: String?,
        threadId: String?,
        attachments: [OutboundMessageRequest.AttachmentContext],
        chatPreviewText: String?,
        optimisticConversation: OptimisticConversationReference?
    ) async throws -> OptimisticSendHandle {
        queue.sync {
            createCalls.append(
                CreateOptimisticCall(
                    recipients: recipients,
                    body: body,
                    subject: subject,
                    threadId: threadId,
                    chatPreviewText: chatPreviewText,
                    optimisticConversation: optimisticConversation,
                    attachmentReferences: attachments.map(\.localAttachmentReference)
                )
            )
        }

        let conversation: Conversation
        if let existingConversationObjectID = optimisticConversation.flatMap({ resolveObjectID(for: $0) }),
           let existingConversation = try? context.existingObject(with: existingConversationObjectID) as? Conversation {
            conversation = existingConversation
        } else {
            conversation = ConversationBuilder()
                .visible()
                .recentlyActive()
                .build(in: context)
        }

        let message = context.insertTestObject(Message.self)
        message.id = "optimistic-\(UUID().uuidString)"
        message.gmThreadId = threadId ?? ""
        message.subject = subject
        message.bodyText = body
        message.chatPreviewText = chatPreviewText
        message.internalDate = Date()
        message.isFromMe = true
        message.conversation = conversation
        try context.obtainPermanentIDs(for: [message])

        queue.sync {
            createdOptimisticMessageObjectIDs.append(message.objectID)
        }
        optimisticMessages[message.id] = message
        return OptimisticSendHandle(
            optimisticMessageID: message.id,
            optimisticMessageObjectID: message.objectID,
            conversationReference: ConversationReference(objectID: conversation.objectID)
        )
    }

    @MainActor
    func markAttachmentsAsUploading(references: [LocalAttachmentReference]) {
        queue.sync {
            markUploadingCalls.append(references)
        }
    }

    func sendReply(
        to recipients: [String],
        fromEmail: String?,
        fromName: String?,
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
                    fromEmail: fromEmail,
                    fromName: fromName,
                    body: body,
                    subject: subject,
                    threadId: threadId,
                    inReplyTo: inReplyTo,
                    references: references,
                    originalMessage: originalMessage
                )
            )
        }

        if sendDelayNanoseconds > 0 {
            try await Task.sleep(nanoseconds: sendDelayNanoseconds)
        }
        if let sendReplyError {
            throw sendReplyError
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
                    subject: subject,
                    inlineAttachmentContentIDs: inlineAttachmentInfos.compactMap(\.contentId)
                )
            )
        }

        if sendDelayNanoseconds > 0 {
            try await Task.sleep(nanoseconds: sendDelayNanoseconds)
        }
        if let sendNewError {
            throw sendNewError
        }

        return GmailSendService.SendResult(
            messageId: "sent-\(UUID().uuidString)",
            threadId: "thread-\(UUID().uuidString)"
        )
    }

    @MainActor
    func remoteCommittedSendResult(optimisticMessageID: String) -> GmailSendService.SendResult? {
        queue.sync {
            remoteCommittedResults[optimisticMessageID]
        }
    }

    @MainActor
    func recordRemoteCommittedSend(
        optimisticMessageID: String,
        result: GmailSendService.SendResult
    ) throws {
        queue.sync {
            remoteCommittedResults[optimisticMessageID] = result
        }
    }

    @MainActor
    func reconcileRemoteCommittedSend(
        optimisticMessageID: String,
        result: GmailSendService.SendResult
    ) throws -> Bool {
        remoteCommittedResults[optimisticMessageID] = nil
        guard let message = optimisticMessages[optimisticMessageID] else {
            return false
        }

        optimisticMessages[optimisticMessageID] = nil
        message.id = result.messageId
        message.gmThreadId = result.threadId
        optimisticMessages[result.messageId] = message
        return true
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
    func markAttachmentsAsUploaded(references: [LocalAttachmentReference]) {}

    @MainActor
    func handleFailedOptimisticMessage(
        byID messageID: String,
        fallbackAttachmentReferences: [LocalAttachmentReference]
    ) {
        optimisticMessages[messageID] = nil
    }

    @MainActor
    private func resolveObjectID(
        for optimisticConversation: OptimisticConversationReference
    ) -> NSManagedObjectID? {
        optimisticConversation.existingConversationReference?.resolveObjectID(in: context)
    }
}

@MainActor
private final class MockOutboundSendMutationTracker: OutboundSendMutationTracking {
    private var pendingMutationIDSet: Set<String> = []
    private(set) var pendingMutationIDs: [String] = []
    private(set) var trackedConversationReferences: [ConversationReference?] = []
    private(set) var successfulMutationIDs: [String] = []
    private(set) var failedMutationIDs: [String] = []

    var pendingMutationCount: Int {
        pendingMutationIDSet.count
    }

    var failedMutations: [OutboundSendMutationTracker.FailedMutation] {
        failedMutationIDs.map {
            .init(
                id: $0,
                conversationReference: nil,
                createdAt: Date(),
                failedAt: Date(),
                errorDescription: "mock"
            )
        }
    }

    func trackPendingMutation(_ mutation: OutboundSendMutationTracker.PendingMutation) {
        pendingMutationIDSet.insert(mutation.id)
        pendingMutationIDs.append(mutation.id)
        trackedConversationReferences.append(mutation.conversationReference)
    }

    func reconcileSuccess(_ success: OutboundMessageReconciliationHooks.Success) {
        pendingMutationIDSet.remove(success.optimisticMessageID)
        successfulMutationIDs.append(success.optimisticMessageID)
    }

    func reconcileFailure(_ failure: OutboundMessageReconciliationHooks.Failure) {
        pendingMutationIDSet.remove(failure.optimisticMessageID)
        failedMutationIDs.append(failure.optimisticMessageID)
    }
}
