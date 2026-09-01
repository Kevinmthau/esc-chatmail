import XCTest
import CoreData
@testable import esc_chatmail

@MainActor
final class OutboundMessageCoordinatorTests: XCTestCase {
    private var coreDataStack: TestCoreDataStack!
    private var htmlContentHandler: HTMLContentHandler!
    private var outboundTaskRegistry: OutboundTaskRegistry!

    override func setUp() {
        super.setUp()
        coreDataStack = TestCoreDataStack()
        htmlContentHandler = HTMLContentHandler()
        outboundTaskRegistry = OutboundTaskRegistry(admissionOpen: true)
    }

    override func tearDown() {
        htmlContentHandler = nil
        coreDataStack = nil
        outboundTaskRegistry = nil
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
        // Compose sends carry no reply metadata; the send service falls back
        // to the session's own From identity for the optimistic message.
        XCTAssertNil(snapshot.createOptimisticCalls.first?.senderEmail)
        XCTAssertNil(snapshot.createOptimisticCalls.first?.senderName)
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

    func testSend_replyPassesFromIdentityToOptimisticMessage() async throws {
        let sendService = MockOutboundMessageSendService(context: coreDataStack.viewContext)
        let syncPerformer = MockCoordinatorSyncPerformer()
        let coordinator = makeCoordinator(
            sendService: sendService,
            syncPerformer: syncPerformer,
            authSession: makeTestAuthSession(
                userEmail: "me@example.com",
                userName: "Me Example"
            )
        )
        let completionExpectation = expectation(description: "reply send completes")

        let context = coreDataStack.viewContext
        let conversation = makeReplyConversation(in: context, friendEmail: "friend@example.com")
        let replyingTo = MessageBuilder()
            .withId("message-identity-1")
            .withThreadId("thread-identity-123")
            .withSubject("Original Subject")
            .withSender(email: "friend@example.com", name: "Friend")
            .withBody("Original body")
            .inConversation(conversation)
            .build(in: context)
        try context.obtainPermanentIDs(for: [conversation, replyingTo])

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
                    body: "Reply body",
                    attachments: []
                )
            ),
            reconciliationHooks: .init(
                onSuccess: { _ in completionExpectation.fulfill() },
                onFailure: nil
            )
        )

        XCTAssertNotNil(submission)
        await fulfillment(of: [completionExpectation], timeout: 1.0)

        // The optimistic message must mirror the exact From identity the MIME
        // will carry, so the sent message's sync echo does not register as a
        // sender-header change (which refreshes every visible bubble).
        let snapshot = sendService.snapshot
        XCTAssertEqual(snapshot.createOptimisticCalls.count, 1)
        XCTAssertEqual(snapshot.createOptimisticCalls.first?.senderEmail, "me@example.com")
        XCTAssertEqual(snapshot.createOptimisticCalls.first?.senderName, "Me Example")
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
        let sourceMessage = MessageBuilder()
            .withId("forward-source-message")
            .withAttachments()
            .build(in: coreDataStack.viewContext)
        let inlineAttachmentID = "inline-attachment"
        let inlinePath = AttachmentPaths.originalPath(
            messageId: sourceMessage.id,
            attachmentId: inlineAttachmentID,
            ext: "png"
        )
        XCTAssertTrue(AttachmentPaths.saveData(Data("inline".utf8), to: inlinePath))
        defer { AttachmentPaths.deleteFile(at: inlinePath) }
        let inlineAttachment = AttachmentBuilder()
            .withId(inlineAttachmentID)
            .withFilename("inline.png")
            .withMimeType("image/png")
            .withLocalURL(inlinePath)
            .downloaded()
            .forMessage(sourceMessage)
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

    func testSend_ambiguousOutcomeClearsPendingTrackerWithoutRecordingFailure() async throws {
        let sendService = MockOutboundMessageSendService(context: coreDataStack.viewContext)
        sendService.sendNewError = GmailSendService.SendError.ambiguousDelivery("connection reset")
        let mutationTracker = MockOutboundSendMutationTracker()
        let coordinator = makeCoordinator(
            sendService: sendService,
            syncPerformer: MockCoordinatorSyncPerformer(),
            mutationTracker: mutationTracker
        )
        let ambiguousExpectation = expectation(description: "ambiguous hook called")
        var ambiguousMessageID: String?

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
                onFailure: nil,
                onAmbiguous: { ambiguous in
                    ambiguousMessageID = ambiguous.optimisticMessageID
                    ambiguousExpectation.fulfill()
                }
            )
        )

        let queuedSubmission = try XCTUnwrap(submission)
        await fulfillment(of: [ambiguousExpectation], timeout: 1.0)
        XCTAssertEqual(ambiguousMessageID, queuedSubmission.optimisticMessageID)
        XCTAssertEqual(mutationTracker.pendingMutationCount, 0)
        XCTAssertEqual(mutationTracker.ambiguousMutationIDs, [queuedSubmission.optimisticMessageID])
        XCTAssertTrue(mutationTracker.failedMutationIDs.isEmpty)
    }

    func testSend_waitsForPreflightAndTransmissionAdmissionBeforeReturning() async throws {
        let preflightGate = OutboundSendTestGate()
        let sendService = MockOutboundMessageSendService(context: coreDataStack.viewContext)
        sendService.sendNewPreflightGate = preflightGate
        let coordinator = makeCoordinator(
            sendService: sendService,
            syncPerformer: MockCoordinatorSyncPerformer()
        )
        var didReturn = false

        let sendTask = Task { @MainActor in
            let result = try await coordinator.send(
                .compose(
                    .init(
                        recipientEmails: ["to@example.com"],
                        subject: "Preflight",
                        body: "Body",
                        attachments: []
                    )
                )
            )
            didReturn = true
            return result
        }

        await preflightGate.waitUntilStarted()
        XCTAssertFalse(didReturn, "The composer-success path must wait for final request admission")

        await preflightGate.release()
        let result = try await sendTask.value

        XCTAssertNotNil(result)
        XCTAssertTrue(didReturn)
    }

    func testSendPublishesDurableOptimisticResultBeforeTransmissionAdmission() async throws {
        let preflightGate = OutboundSendTestGate()
        let sendService = MockOutboundMessageSendService(context: coreDataStack.viewContext)
        sendService.sendNewPreflightGate = preflightGate
        let coordinator = makeCoordinator(
            sendService: sendService,
            syncPerformer: MockCoordinatorSyncPerformer()
        )
        var presentationEvents: [String] = []
        var optimisticResult: OutboundMessageResult?
        var didReturn = false

        let sendTask = Task { @MainActor in
            let result = try await coordinator.send(
                .compose(
                    .init(
                        recipientEmails: ["to@example.com"],
                        subject: "Immediate optimistic presentation",
                        body: "Body",
                        attachments: []
                    )
                ),
                onOptimisticMessagePersisted: { result in
                    optimisticResult = result
                    presentationEvents.append("optimistic-persisted")
                }
            )
            didReturn = true
            presentationEvents.append("transmission-admitted")
            return result
        }

        await preflightGate.waitUntilStarted()

        let persistedResult = try XCTUnwrap(optimisticResult)
        XCTAssertFalse(didReturn)
        XCTAssertEqual(presentationEvents, ["optimistic-persisted"])
        XCTAssertEqual(
            persistedResult.optimisticMessageObjectID,
            sendService.snapshot.createdOptimisticMessageObjectIDs.last
        )

        await preflightGate.release()
        let admittedSubmission = try await sendTask.value
        let admittedResult = try XCTUnwrap(admittedSubmission)

        XCTAssertEqual(admittedResult.optimisticMessageID, persistedResult.optimisticMessageID)
        XCTAssertEqual(
            presentationEvents,
            ["optimistic-persisted", "transmission-admitted"]
        )
    }

    func testSend_preflightFailureAfterOptimisticPublicationRollsBackAndClearsPendingMutation() async throws {
        let preflightGate = OutboundSendTestGate()
        let sendService = MockOutboundMessageSendService(context: coreDataStack.viewContext)
        sendService.sendNewPreflightGate = preflightGate
        sendService.sendNewPreflightError = GmailSendService.SendError.apiError("preflight")
        let mutationTracker = MockOutboundSendMutationTracker()
        let coordinator = makeCoordinator(
            sendService: sendService,
            syncPerformer: MockCoordinatorSyncPerformer(),
            mutationTracker: mutationTracker
        )
        var optimisticResult: OutboundMessageResult?
        var callbackCount = 0
        var sendError: Error?

        let sendTask = Task { @MainActor in
            do {
                _ = try await coordinator.send(
                    .compose(
                        .init(
                            recipientEmails: ["to@example.com"],
                            subject: "Preflight failure",
                            body: "Body",
                            attachments: []
                        )
                    ),
                    onOptimisticMessagePersisted: { result in
                        optimisticResult = result
                        callbackCount += 1
                    }
                )
                XCTFail("Expected preflight failure")
            } catch {
                sendError = error
            }
        }

        await preflightGate.waitUntilStarted()

        let persistedResult = try XCTUnwrap(optimisticResult)
        XCTAssertEqual(callbackCount, 1)
        XCTAssertEqual(mutationTracker.pendingMutationIDs, [persistedResult.optimisticMessageID])
        XCTAssertEqual(mutationTracker.pendingMutationCount, 1)
        XCTAssertNotNil(sendService.fetchMessageSync(byID: persistedResult.optimisticMessageID))
        XCTAssertTrue(sendService.snapshot.rolledBackOptimisticMessageIDs.isEmpty)
        XCTAssertTrue(sendService.snapshot.recordRemoteSendAdmissionCalls.isEmpty)
        XCTAssertEqual(sendService.snapshot.remoteTransmissionCalls, 0)

        await preflightGate.release()
        await sendTask.value

        XCTAssertNotNil(sendError)
        XCTAssertEqual(callbackCount, 1)
        XCTAssertNil(sendService.fetchMessageSync(byID: persistedResult.optimisticMessageID))
        XCTAssertEqual(
            sendService.snapshot.rolledBackOptimisticMessageIDs,
            [persistedResult.optimisticMessageID]
        )
        XCTAssertEqual(
            sendService.snapshot.failedOptimisticMessageIDs,
            [persistedResult.optimisticMessageID]
        )
        XCTAssertEqual(mutationTracker.pendingMutationCount, 0)
        XCTAssertEqual(mutationTracker.failedMutationIDs, [persistedResult.optimisticMessageID])
        XCTAssertTrue(sendService.snapshot.recordRemoteSendAdmissionCalls.isEmpty)
        XCTAssertEqual(sendService.snapshot.remoteTransmissionCalls, 0)
        XCTAssertTrue(sendService.snapshot.sendNewCancellationObservations.isEmpty)
    }

    func testSend_closedAdmissionRejectsBeforeOptimisticCreation() async {
        let sendService = MockOutboundMessageSendService(context: coreDataStack.viewContext)
        let coordinator = makeCoordinator(
            sendService: sendService,
            syncPerformer: MockCoordinatorSyncPerformer()
        )
        outboundTaskRegistry.closeAdmission()

        do {
            _ = try await coordinator.send(
                .compose(
                    .init(
                        recipientEmails: ["to@example.com"],
                        subject: "Blocked",
                        body: "Body",
                        attachments: []
                    )
                )
            )
            XCTFail("Expected account-transition admission to reject the send")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertTrue(sendService.snapshot.createOptimisticCalls.isEmpty)
        XCTAssertTrue(sendService.snapshot.sendNewCalls.isEmpty)
    }

    func testRegistry_newerAccountTransitionPreventsOlderReopen() {
        let olderTransition = outboundTaskRegistry.closeAdmission()
        let newerTransition = outboundTaskRegistry.closeAdmission()

        XCTAssertEqual(
            outboundTaskRegistry.reopenAdmission(after: olderTransition),
            .supersededByNewerTransition
        )
        XCTAssertNil(outboundTaskRegistry.reserve())
        XCTAssertEqual(outboundTaskRegistry.reopenAdmission(after: newerTransition), .reopened)

        let reservation = outboundTaskRegistry.reserve()
        XCTAssertNotNil(reservation)
        if let reservation {
            outboundTaskRegistry.finish(reservation)
        }
    }

    // Revert-check: fails if OutboundTaskRegistry.reopenAdmission(after:)
    // collapses its two refusal causes back into one (the pre-split Bool):
    // the undrained reservation stops reporting .undrainedSends, or draining
    // it stops flipping the same transition's result to .reopened. AuthSession
    // maps .undrainedSends to .latchedRefusal, whose restore disposition is
    // credential discard — a supersession verdict would instead keep the
    // credentials and wait for a queued sign-out that does not exist.
    func testRegistry_undrainedReservationRefusesReopenUntilFinished() throws {
        let reservation = try XCTUnwrap(outboundTaskRegistry.reserve())
        let transition = outboundTaskRegistry.closeAdmission()

        XCTAssertEqual(
            outboundTaskRegistry.reopenAdmission(after: transition),
            .undrainedSends,
            "A current transition with an undrained reservation is latched, not superseded"
        )
        XCTAssertNil(outboundTaskRegistry.reserve())

        outboundTaskRegistry.finish(reservation)
        XCTAssertEqual(
            outboundTaskRegistry.reopenAdmission(after: transition),
            .reopened,
            "The latch is the reservation, not the generation"
        )
        let postDrainReservation = outboundTaskRegistry.reserve()
        XCTAssertNotNil(postDrainReservation)
        if let postDrainReservation {
            outboundTaskRegistry.finish(postDrainReservation)
        }
    }

    // Revert-check: fails if reopenAdmission(after:) checks entries before the
    // transition generation. When a stale transition also finds an undrained
    // reservation, the newer transition owns the account boundary; reporting
    // .undrainedSends would route AuthSession to .latchedRefusal and a launch
    // restore into discarding credentials whose cleanup the superseding
    // sign-out already owns.
    func testRegistry_staleTransitionWithUndrainedReservationReportsSupersession() throws {
        let reservation = try XCTUnwrap(outboundTaskRegistry.reserve())
        let staleTransition = outboundTaskRegistry.closeAdmission()
        let newerTransition = outboundTaskRegistry.closeAdmission()

        XCTAssertEqual(
            outboundTaskRegistry.reopenAdmission(after: staleTransition),
            .supersededByNewerTransition,
            "Supersession must win over the latch: only the newest transition may see .undrainedSends"
        )
        XCTAssertEqual(
            outboundTaskRegistry.reopenAdmission(after: newerTransition),
            .undrainedSends
        )

        outboundTaskRegistry.finish(reservation)
        XCTAssertEqual(
            outboundTaskRegistry.reopenAdmission(after: staleTransition),
            .supersededByNewerTransition,
            "Draining must not resurrect a superseded transition"
        )
        XCTAssertEqual(outboundTaskRegistry.reopenAdmission(after: newerTransition), .reopened)
    }

    // Revert-check: fails if reopenAdmission(after:) drops its already-open
    // short-circuit and reports .undrainedSends for a healthy, open admission
    // with in-flight sends of the current account — a verdict AuthSession
    // answers with the destructive .latchedRefusal rollback against a session
    // that is working correctly.
    func testRegistry_repeatReopenWithLiveSendsReportsReopenedNotUndrained() throws {
        let transition = outboundTaskRegistry.closeAdmission()
        XCTAssertEqual(outboundTaskRegistry.reopenAdmission(after: transition), .reopened)
        let liveSend = try XCTUnwrap(outboundTaskRegistry.reserve())

        XCTAssertEqual(
            outboundTaskRegistry.reopenAdmission(after: transition),
            .reopened,
            "A repeat reopen for an open admission must not mistake live sends for an undrained latch"
        )
        let admissionStillOpen = outboundTaskRegistry.reserve()
        XCTAssertNotNil(
            admissionStillOpen,
            "The repeat reopen must leave the open admission untouched"
        )
        if let admissionStillOpen {
            outboundTaskRegistry.finish(admissionStillOpen)
        }
        outboundTaskRegistry.finish(liveSend)
    }

    func testRegistry_closeDuringSuccessfulMarkerPersistenceDrainsAdmittedTask() async throws {
        let gate = OutboundSendTestGate()
        let reservation = try XCTUnwrap(outboundTaskRegistry.reserve())
        let backgroundTask = Task {
            await gate.waitUntilReleased()
        }
        var cancellationRequests = 0
        XCTAssertTrue(
            outboundTaskRegistry.handOff(
                reservation,
                to: backgroundTask,
                cancelBeforeTransmission: {
                    cancellationRequests += 1
                    backgroundTask.cancel()
                }
            )
        )
        await gate.waitUntilStarted()

        try outboundTaskRegistry.admitTransmission(
            reservation,
            persistingMarker: {
                outboundTaskRegistry.closeAdmission()
            }
        )

        XCTAssertEqual(cancellationRequests, 0)
        XCTAssertFalse(backgroundTask.isCancelled)

        let drainTask = Task { @MainActor in
            await outboundTaskRegistry.cancelAndAwaitAll()
        }
        await gate.release()
        await drainTask.value
        XCTAssertEqual(cancellationRequests, 0)
    }

    func testRegistry_closeDuringFailedMarkerPersistenceCancelsPreflightTask() async throws {
        let gate = OutboundSendTestGate()
        let reservation = try XCTUnwrap(outboundTaskRegistry.reserve())
        let backgroundTask = Task {
            await gate.waitUntilReleased()
        }
        var cancellationRequests = 0
        XCTAssertTrue(
            outboundTaskRegistry.handOff(
                reservation,
                to: backgroundTask,
                cancelBeforeTransmission: {
                    cancellationRequests += 1
                    backgroundTask.cancel()
                }
            )
        )
        await gate.waitUntilStarted()

        XCTAssertThrowsError(
            try outboundTaskRegistry.admitTransmission(
                reservation,
                persistingMarker: {
                    outboundTaskRegistry.closeAdmission()
                    throw GmailSendService.SendError.optimisticCreationFailed
                }
            )
        )
        XCTAssertEqual(cancellationRequests, 1)
        XCTAssertTrue(backgroundTask.isCancelled)

        let drainTask = Task { @MainActor in
            await outboundTaskRegistry.cancelAndAwaitAll()
        }
        await gate.release()
        await drainTask.value
    }

    func testRegistry_handoffAfterAdmissionDoesNotReinstallPreflightCancellation() async throws {
        let gate = OutboundSendTestGate()
        let reservation = try XCTUnwrap(outboundTaskRegistry.reserve())
        let backgroundTask = Task {
            await gate.waitUntilReleased()
        }
        await gate.waitUntilStarted()

        try outboundTaskRegistry.admitTransmission(
            reservation,
            persistingMarker: {}
        )
        outboundTaskRegistry.closeAdmission()

        var cancellationRequests = 0
        XCTAssertFalse(
            outboundTaskRegistry.handOff(
                reservation,
                to: backgroundTask,
                cancelBeforeTransmission: {
                    cancellationRequests += 1
                    backgroundTask.cancel()
                }
            )
        )
        XCTAssertEqual(cancellationRequests, 0)
        XCTAssertFalse(backgroundTask.isCancelled)

        let drainTask = Task { @MainActor in
            await outboundTaskRegistry.cancelAndAwaitAll()
        }
        await gate.release()
        await drainTask.value
        XCTAssertEqual(cancellationRequests, 0)
    }

    func testSend_accountTransitionDrainsRequestBuilderBeforeReopen() async {
        let requestBuilderGate = OutboundSendTestGate()
        let sendService = MockOutboundMessageSendService(context: coreDataStack.viewContext)
        let coordinator = makeCoordinator(
            sendService: sendService,
            syncPerformer: MockCoordinatorSyncPerformer()
        )

        let sendTask = Task { @MainActor in
            do {
                _ = try await coordinator.send(preparing: {
                    await requestBuilderGate.waitUntilReleased()
                    return .compose(
                        .init(
                            recipientEmails: ["old-account-recipient@example.com"],
                            subject: "Old account draft",
                            body: "Body",
                            attachments: []
                        )
                    )
                })
                return false
            } catch is CancellationError {
                return true
            } catch {
                XCTFail("Unexpected error: \(error)")
                return false
            }
        }
        await requestBuilderGate.waitUntilStarted()

        let transition = outboundTaskRegistry.closeAdmission()
        XCTAssertEqual(
            outboundTaskRegistry.reopenAdmission(after: transition),
            .undrainedSends,
            "The request builder must own a reservation before its first suspension"
        )

        var didDrain = false
        let drainTask = Task { @MainActor in
            await outboundTaskRegistry.cancelAndAwaitAll()
            didDrain = true
        }
        for _ in 0..<20 {
            await Task.yield()
        }
        XCTAssertFalse(didDrain, "Account teardown must await the suspended request builder")

        await requestBuilderGate.release()
        let wasCancelled = await sendTask.value
        await drainTask.value

        XCTAssertTrue(wasCancelled)
        XCTAssertTrue(didDrain)
        XCTAssertEqual(outboundTaskRegistry.reopenAdmission(after: transition), .reopened)
        XCTAssertTrue(sendService.snapshot.createOptimisticCalls.isEmpty)
        XCTAssertTrue(sendService.snapshot.sendNewCalls.isEmpty)
    }

    func testSend_accountTransitionDrainsPreparationAndPreventsBackgroundHandoff() async {
        let optimisticGate = OutboundSendTestGate()
        let sendService = MockOutboundMessageSendService(context: coreDataStack.viewContext)
        sendService.optimisticCreationGate = optimisticGate
        let coordinator = makeCoordinator(
            sendService: sendService,
            syncPerformer: MockCoordinatorSyncPerformer()
        )

        let sendTask = Task { @MainActor in
            do {
                _ = try await coordinator.send(
                    .compose(
                        .init(
                            recipientEmails: ["to@example.com"],
                            subject: "Preparing",
                            body: "Body",
                            attachments: []
                        )
                    )
                )
                return false
            } catch is CancellationError {
                return true
            } catch {
                XCTFail("Unexpected error: \(error)")
                return false
            }
        }
        await optimisticGate.waitUntilStarted()

        outboundTaskRegistry.closeAdmission()
        var didDrain = false
        let drainTask = Task { @MainActor in
            await outboundTaskRegistry.cancelAndAwaitAll()
            didDrain = true
        }
        for _ in 0..<20 {
            await Task.yield()
        }
        XCTAssertFalse(didDrain, "Teardown must retain the pre-handoff reservation")

        await optimisticGate.release()
        let wasCancelled = await sendTask.value
        XCTAssertTrue(wasCancelled)
        await drainTask.value

        XCTAssertTrue(didDrain)
        XCTAssertEqual(sendService.snapshot.createOptimisticCalls.count, 1)
        XCTAssertTrue(sendService.snapshot.sendNewCalls.isEmpty)
        XCTAssertEqual(sendService.snapshot.failedOptimisticMessageIDs.count, 1)
    }

    func testSend_accountTransitionDuringPreflightCancelsWorkerAndPreventsGmailAdmission() async {
        let preflightGate = OutboundSendTestGate()
        let sendService = MockOutboundMessageSendService(context: coreDataStack.viewContext)
        sendService.sendNewPreflightGate = preflightGate
        let coordinator = makeCoordinator(
            sendService: sendService,
            syncPerformer: MockCoordinatorSyncPerformer()
        )

        let sendTask = Task { @MainActor in
            do {
                _ = try await coordinator.send(
                    .compose(
                        .init(
                            recipientEmails: ["to@example.com"],
                            subject: "Cancelled preflight",
                            body: "Body",
                            attachments: []
                        )
                    )
                )
                return false
            } catch is CancellationError {
                return true
            } catch {
                XCTFail("Unexpected error: \(error)")
                return false
            }
        }
        await preflightGate.waitUntilStarted()

        outboundTaskRegistry.closeAdmission()
        var didDrain = false
        let drainTask = Task { @MainActor in
            await outboundTaskRegistry.cancelAndAwaitAll()
            didDrain = true
        }
        for _ in 0..<20 {
            await Task.yield()
        }
        XCTAssertFalse(didDrain, "Teardown must retain the cancelled preflight task")

        await preflightGate.release()
        let wasCancelled = await sendTask.value
        XCTAssertTrue(wasCancelled)
        await drainTask.value

        let snapshot = sendService.snapshot
        XCTAssertTrue(didDrain)
        XCTAssertEqual(snapshot.sendNewCalls.count, 1)
        XCTAssertEqual(snapshot.sendNewPreflightCancellationObservations, [true])
        XCTAssertTrue(snapshot.recordRemoteSendAdmissionCalls.isEmpty)
        XCTAssertEqual(snapshot.remoteTransmissionCalls, 0)
        XCTAssertEqual(snapshot.failedOptimisticMessageIDs.count, 1)
    }

    func testSend_accountTransitionDoesNotCancelStartedGmailCallAndDrainsThroughSuccess() async throws {
        let sendGate = OutboundSendTestGate()
        let sendService = MockOutboundMessageSendService(context: coreDataStack.viewContext)
        sendService.sendNewGate = sendGate
        let syncPerformer = MockCoordinatorSyncPerformer()
        let mutationTracker = MockOutboundSendMutationTracker()
        let coordinator = makeCoordinator(
            sendService: sendService,
            syncPerformer: syncPerformer,
            mutationTracker: mutationTracker
        )
        var successIDs: [String] = []
        var failureIDs: [String] = []

        let optionalSubmission = try await coordinator.send(
            .compose(
                .init(
                    recipientEmails: ["to@example.com"],
                    subject: "In flight",
                    body: "Body",
                    attachments: []
                )
            ),
            reconciliationHooks: .init(
                onSuccess: { success in successIDs.append(success.optimisticMessageID) },
                onFailure: { failure in failureIDs.append(failure.optimisticMessageID) }
            )
        )
        let submission = try XCTUnwrap(optionalSubmission)
        await sendGate.waitUntilStarted()

        outboundTaskRegistry.closeAdmission()
        var didDrain = false
        let drainTask = Task { @MainActor in
            await outboundTaskRegistry.cancelAndAwaitAll()
            didDrain = true
        }
        for _ in 0..<20 {
            await Task.yield()
        }
        XCTAssertFalse(didDrain, "Teardown must await an API call that ignores cancellation")
        XCTAssertTrue(successIDs.isEmpty)

        await sendGate.release()
        await drainTask.value

        XCTAssertTrue(didDrain)
        XCTAssertEqual(sendService.snapshot.sendNewCancellationObservations, [false])
        XCTAssertEqual(successIDs, [submission.optimisticMessageID])
        XCTAssertTrue(failureIDs.isEmpty)
        XCTAssertEqual(mutationTracker.successfulMutationIDs, [submission.optimisticMessageID])
        XCTAssertTrue(mutationTracker.failedMutationIDs.isEmpty)
        XCTAssertTrue(sendService.snapshot.failedOptimisticMessageIDs.isEmpty)
        XCTAssertEqual(syncPerformer.performIncrementalSyncCalls, 1)
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
            mutationTracker: mutationTracker ?? MockOutboundSendMutationTracker(),
            outboundTaskRegistry: outboundTaskRegistry
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

    private func makeTestAuthSession(
        userEmail: String? = nil,
        userName: String? = nil
    ) -> AuthSession {
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
        authSession.userName = userName
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
        let senderEmail: String?
        let senderName: String?
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
        let failedOptimisticMessageIDs: [String]
        let rolledBackOptimisticMessageIDs: [String]
        let sendNewCancellationObservations: [Bool]
        let sendNewPreflightCancellationObservations: [Bool]
        let recordRemoteSendAdmissionCalls: [String]
        let remoteTransmissionCalls: Int
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
    private var failedOptimisticMessageIDs: [String] = []
    private var rolledBackOptimisticMessageIDs: [String] = []
    private var sendNewCancellationObservations: [Bool] = []
    private var sendNewPreflightCancellationObservations: [Bool] = []
    private var recordRemoteSendAdmissionCalls: [String] = []
    private var remoteTransmissionCalls = 0
    var sendDelayNanoseconds: UInt64 = 0
    var sendNewError: Error?
    var sendReplyError: Error?
    var optimisticCreationGate: OutboundSendTestGate?
    var sendNewPreflightGate: OutboundSendTestGate?
    var sendNewPreflightError: Error?
    var sendNewGate: OutboundSendTestGate?

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
                markAttachmentsAsUploadingCalls: markUploadingCalls,
                failedOptimisticMessageIDs: failedOptimisticMessageIDs,
                rolledBackOptimisticMessageIDs: rolledBackOptimisticMessageIDs,
                sendNewCancellationObservations: sendNewCancellationObservations,
                sendNewPreflightCancellationObservations: sendNewPreflightCancellationObservations,
                recordRemoteSendAdmissionCalls: recordRemoteSendAdmissionCalls,
                remoteTransmissionCalls: remoteTransmissionCalls
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
        senderEmail: String?,
        senderName: String?,
        optimisticConversation: OptimisticConversationReference?
    ) async throws -> OptimisticSendHandle {
        if let optimisticCreationGate {
            await optimisticCreationGate.waitUntilReleased()
        }
        queue.sync {
            createCalls.append(
                CreateOptimisticCall(
                    recipients: recipients,
                    body: body,
                    subject: subject,
                    threadId: threadId,
                    chatPreviewText: chatPreviewText,
                    senderEmail: senderEmail,
                    senderName: senderName,
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
        attachmentInfos: [GmailSendService.AttachmentInfo],
        messageId: String?,
        beforeTransmission: @Sendable () async throws -> Void
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

        try await beforeTransmission()
        queue.sync { remoteTransmissionCalls += 1 }

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
        inlineAttachmentInfos: [GmailSendService.AttachmentInfo],
        messageId: String?,
        beforeTransmission: @Sendable () async throws -> Void
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

        if let sendNewPreflightGate {
            await sendNewPreflightGate.waitUntilReleased()
            let wasCancelled = Task.isCancelled
            queue.sync {
                sendNewPreflightCancellationObservations.append(wasCancelled)
            }
        }
        if let sendNewPreflightError {
            throw sendNewPreflightError
        }

        try await beforeTransmission()
        queue.sync { remoteTransmissionCalls += 1 }

        if let sendNewGate {
            await sendNewGate.waitUntilReleased()
            let wasCancelled = Task.isCancelled
            queue.sync {
                sendNewCancellationObservations.append(wasCancelled)
            }
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
    func persistOptimisticMessageBeforeTransmission(optimisticMessageID: String) throws {}

    @MainActor
    func recordRemoteSendAdmission(optimisticMessageID: String) throws {
        queue.sync {
            recordRemoteSendAdmissionCalls.append(optimisticMessageID)
        }
    }

    @MainActor
    func recordAmbiguousRemoteSend(optimisticMessageID: String) throws {}

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
    func rollbackOptimisticMessageBeforeTransmission(
        byID messageID: String,
        fallbackAttachmentReferences: [LocalAttachmentReference]
    ) {
        queue.sync {
            failedOptimisticMessageIDs.append(messageID)
            rolledBackOptimisticMessageIDs.append(messageID)
        }
        optimisticMessages[messageID] = nil
    }

    @MainActor
    func retainDefinitelyUnsentOptimisticMessage(
        byID messageID: String,
        fallbackAttachmentReferences: [LocalAttachmentReference]
    ) {
        queue.sync {
            failedOptimisticMessageIDs.append(messageID)
        }
    }

    @MainActor
    private func resolveObjectID(
        for optimisticConversation: OptimisticConversationReference
    ) -> NSManagedObjectID? {
        optimisticConversation.existingConversationReference?.resolveObjectID(in: context)
    }
}

private actor OutboundSendTestGate {
    private var started = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func waitUntilReleased() async {
        started = true
        let waiters = startWaiters
        startWaiters.removeAll(keepingCapacity: false)
        waiters.forEach { $0.resume() }

        await withCheckedContinuation { continuation in
            releaseWaiters.append(continuation)
        }
    }

    func waitUntilStarted() async {
        guard !started else { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func release() {
        let waiters = releaseWaiters
        releaseWaiters.removeAll(keepingCapacity: false)
        waiters.forEach { $0.resume() }
    }
}

@MainActor
private final class MockOutboundSendMutationTracker: OutboundSendMutationTracking {
    private var pendingMutationIDSet: Set<String> = []
    private(set) var pendingMutationIDs: [String] = []
    private(set) var trackedConversationReferences: [ConversationReference?] = []
    private(set) var successfulMutationIDs: [String] = []
    private(set) var failedMutationIDs: [String] = []
    private(set) var ambiguousMutationIDs: [String] = []

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

    func reconcileAmbiguous(_ ambiguous: OutboundMessageReconciliationHooks.Ambiguous) {
        pendingMutationIDSet.remove(ambiguous.optimisticMessageID)
        ambiguousMutationIDs.append(ambiguous.optimisticMessageID)
    }
}
