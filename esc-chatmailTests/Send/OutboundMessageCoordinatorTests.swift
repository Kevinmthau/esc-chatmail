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
        XCTAssertEqual(snapshot.createOptimisticCalls.first?.recipients, ["to@example.com"])
        XCTAssertEqual(snapshot.createOptimisticCalls.first?.body, "Hello world")
        XCTAssertNil(snapshot.createOptimisticCalls.first?.subject)
        XCTAssertEqual(snapshot.sendNewCalls.count, 1)
        XCTAssertEqual(snapshot.sendNewCalls.first?.body, "Hello world")
        XCTAssertNil(snapshot.sendNewCalls.first?.subject)
        XCTAssertEqual(snapshot.sendReplyCalls.count, 0)
        XCTAssertNotNil(queuedSubmission.conversationObjectID)
        XCTAssertEqual(syncPerformer.performIncrementalSyncCalls, 1)
        XCTAssertEqual(mutationTracker.pendingMutationIDs, [queuedSubmission.optimisticMessageID])
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
        let conversation = ConversationBuilder()
            .withDisplayName("Reply Thread")
            .visible()
            .recentlyActive()
            .build(in: context)

        let submission = try await coordinator.send(
            .reply(
                .init(
                    context: .init(
                        recipientEmails: ["friend@example.com"],
                        subject: "Re: Original Subject",
                        threadId: "thread-123",
                        inReplyTo: "<message-1@example.com>",
                        references: ["<older@example.com>", "<message-1@example.com>"],
                        originalMessage: QuotedMessage(
                            senderName: "Friend",
                            senderEmail: "friend@example.com",
                            date: Date(timeIntervalSince1970: 1_700_000_000),
                            body: "Original body"
                        ),
                        existingConversation: .init(objectID: conversation.objectID)
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
        XCTAssertEqual(snapshot.createOptimisticCalls.first?.existingConversation?.objectID, conversation.objectID)
        XCTAssertEqual(snapshot.sendNewCalls.count, 0)
        XCTAssertEqual(snapshot.sendReplyCalls.count, 1)
        XCTAssertEqual(snapshot.sendReplyCalls.first?.recipients, ["friend@example.com"])
        XCTAssertEqual(snapshot.sendReplyCalls.first?.body, "Reply body")
        XCTAssertEqual(snapshot.sendReplyCalls.first?.subject, "Re: Original Subject")
        XCTAssertEqual(snapshot.sendReplyCalls.first?.threadId, "thread-123")
        XCTAssertEqual(snapshot.sendReplyCalls.first?.inReplyTo, "<message-1@example.com>")
        XCTAssertEqual(snapshot.sendReplyCalls.first?.references, ["<older@example.com>", "<message-1@example.com>"])
        XCTAssertEqual(syncPerformer.performIncrementalSyncCalls, 1)
        XCTAssertEqual(mutationTracker.pendingMutationIDs, [queuedSubmission.optimisticMessageID])
        XCTAssertEqual(mutationTracker.successfulMutationIDs, [queuedSubmission.optimisticMessageID])
    }

    func testSend_forwardBuildsCombinedBodiesUsesInlineSnapshotsAndRunsSendNew() async throws {
        let sendService = MockOutboundMessageSendService(context: coreDataStack.viewContext)
        let syncPerformer = MockCoordinatorSyncPerformer()
        let coordinator = makeCoordinator(sendService: sendService, syncPerformer: syncPerformer)
        let completionExpectation = expectation(description: "forward send completes")
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
                    forwardedInlineAttachments: [inlineAttachment]
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
        XCTAssertEqual(snapshot.createOptimisticCalls.first?.body, "Intro line\n\nForwarded plain text")
        XCTAssertEqual(snapshot.sendNewCalls.count, 1)
        XCTAssertEqual(snapshot.sendNewCalls.first?.body, "Intro line\n\nForwarded plain text")
        XCTAssertEqual(snapshot.sendNewCalls.first?.subject, "Fwd: Hello")
        XCTAssertTrue(snapshot.sendNewCalls.first?.htmlBody?.contains("Intro line") == true)
        XCTAssertTrue(snapshot.sendNewCalls.first?.htmlBody?.contains("Forwarded HTML") == true)
        XCTAssertEqual(snapshot.attachmentToInfoCalls.count, 0)
        XCTAssertEqual(snapshot.attachmentSnapshotCalls.map(\.contentId), ["cid-inline"])
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
            mutationTracker: mutationTracker ?? MockOutboundSendMutationTracker()
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
    struct AttachmentInfoCall {
        let filename: String
        let contentId: String?
    }

    struct CreateOptimisticCall {
        let recipients: [String]
        let body: String
        let subject: String?
        let threadId: String?
        let existingConversation: OutboundMessageRequest.ExistingConversationContext?
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
        let attachmentToInfoCalls: [AttachmentInfoCall]
        let attachmentSnapshotCalls: [AttachmentInfoCall]
    }

    private let context: NSManagedObjectContext
    private let queue = DispatchQueue(label: "OutboundMessageCoordinatorTests.MockSendService")
    private var optimisticMessages: [String: Message] = [:]
    private var createCalls: [CreateOptimisticCall] = []
    private var newCalls: [SendNewCall] = []
    private var replyCalls: [SendReplyCall] = []
    private var attachmentInfoCalls: [AttachmentInfoCall] = []
    private var attachmentSnapshotCalls: [AttachmentInfoCall] = []
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
                sendNewCalls: newCalls,
                sendReplyCalls: replyCalls,
                attachmentToInfoCalls: attachmentInfoCalls,
                attachmentSnapshotCalls: attachmentSnapshotCalls
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
        existingConversation: OutboundMessageRequest.ExistingConversationContext?
    ) async throws -> Message {
        queue.sync {
            createCalls.append(
                CreateOptimisticCall(
                    recipients: recipients,
                    body: body,
                    subject: subject,
                    threadId: threadId,
                    existingConversation: existingConversation
                )
            )
        }

        let conversation: Conversation
        if let existingConversationObjectID = existingConversation?.objectID,
           let existingConversation = try? context.existingObject(with: existingConversationObjectID) as? Conversation {
            conversation = existingConversation
        } else {
            conversation = ConversationBuilder()
                .visible()
                .recentlyActive()
                .build(in: context)
        }

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
        queue.sync {
            attachmentInfoCalls.append(
                AttachmentInfoCall(
                    filename: attachment.filenameValue,
                    contentId: attachment.contentId
                )
            )
        }
        return GmailSendService.AttachmentInfo(
            localURL: attachment.localURLValue,
            filename: attachment.filenameValue,
            mimeType: attachment.mimeTypeValue,
            contentId: attachment.contentId
        )
    }

    func attachmentSnapshot(_ attachment: Attachment) -> GmailSendService.AttachmentInfo {
        queue.sync {
            attachmentSnapshotCalls.append(
                AttachmentInfoCall(
                    filename: attachment.filenameValue,
                    contentId: attachment.contentId
                )
            )
        }
        return GmailSendService.AttachmentInfo(
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
                    subject: subject
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
    func markAttachmentsAsUploaded(objectIDs: [NSManagedObjectID]) {}

    @MainActor
    func handleFailedOptimisticMessage(byID messageID: String, fallbackAttachmentObjectIDs: [NSManagedObjectID]) {
        optimisticMessages[messageID] = nil
    }
}

@MainActor
private final class MockOutboundSendMutationTracker: OutboundSendMutationTracking {
    private var pendingMutationIDSet: Set<String> = []
    private(set) var pendingMutationIDs: [String] = []
    private(set) var successfulMutationIDs: [String] = []
    private(set) var failedMutationIDs: [String] = []

    var pendingMutationCount: Int {
        pendingMutationIDSet.count
    }

    var failedMutations: [OutboundSendMutationTracker.FailedMutation] {
        failedMutationIDs.map {
            .init(
                id: $0,
                conversationObjectURI: nil,
                createdAt: Date(),
                failedAt: Date(),
                errorDescription: "mock"
            )
        }
    }

    func trackPendingMutation(_ mutation: OutboundSendMutationTracker.PendingMutation) {
        pendingMutationIDSet.insert(mutation.id)
        pendingMutationIDs.append(mutation.id)
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
