import XCTest
import CoreData
@testable import esc_chatmail

@MainActor
final class GmailSendServiceOptimisticFailureTests: XCTestCase {
    private var coreDataStack: TestCoreDataStack!
    private var sendService: GmailSendService!

    override func setUp() {
        super.setUp()
        coreDataStack = TestCoreDataStack()
        sendService = GmailSendService(viewContext: coreDataStack.viewContext)
    }

    override func tearDown() {
        sendService = nil
        coreDataStack = nil
        super.tearDown()
    }

    func testHandleFailedOptimisticMessage_withoutLocalAttachments_deletesOptimisticMessage() throws {
        let context = coreDataStack.viewContext
        let conversation = ConversationBuilder()
            .visible()
            .recentlyActive()
            .build(in: context)

        let messageID = "optimistic-no-attachments"
        let message = MessageBuilder()
            .withId(messageID)
            .fromMe()
            .inConversation(conversation)
            .build(in: context)

        try coreDataStack.saveViewContext()
        XCTAssertNotNil(sendService.fetchMessageSync(byID: messageID))

        sendService.handleFailedOptimisticMessage(message)

        XCTAssertNil(sendService.fetchMessageSync(byID: messageID))
    }

    func testHandleFailedOptimisticMessage_withoutLocalAttachments_deletesNewEmptyOptimisticConversation() async throws {
        let context = coreDataStack.viewContext
        let recipient = "new-thread@example.com"
        let participantHash = calculateParticipantHash(from: [normalizedEmail(recipient)])

        let handle = try await sendService.createOptimisticMessage(
            to: [recipient],
            body: "This send will fail",
            optimisticConversation: .participantHash(participantHash)
        )

        let message = try XCTUnwrap(sendService.fetchMessageSync(byID: handle.optimisticMessageID))
        let conversation = try XCTUnwrap(message.conversation)
        XCTAssertFalse(conversation.isInserted)
        XCTAssertEqual(try conversationCount(in: context), 1)

        sendService.handleFailedOptimisticMessage(message)

        XCTAssertNil(sendService.fetchMessageSync(byID: handle.optimisticMessageID))
        XCTAssertEqual(try conversationCount(in: context), 0)
    }

    func testHandleFailedOptimisticMessage_afterOptimisticUnarchive_restoresArchivedConversationState() async throws {
        let context = coreDataStack.viewContext
        let recipient = "archived-thread@example.com"
        let participantHash = calculateParticipantHash(from: [normalizedEmail(recipient)])
        let archivedAt = Date(timeIntervalSince1970: 100)
        let previousMessageDate = Date(timeIntervalSince1970: 50)

        let archivedConversation = ConversationBuilder()
            .withParticipantHash(participantHash)
            .withDisplayName("Archived Thread")
            .withSnippet("Previous received message")
            .withLastMessageDate(previousMessageDate)
            .hasInboxMessages(false)
            .archivedOn(archivedAt)
            .setHidden()
            .build(in: context)

        let nonInboxLabel = LabelBuilder()
            .withId("CATEGORY_PERSONAL")
            .withName("Personal")
            .build(in: context)
        let previousMessage = MessageBuilder()
            .withId("previous-received-message")
            .withDate(previousMessageDate)
            .withSnippet("Previous received message")
            .inConversation(archivedConversation)
            .build(in: context)
        previousMessage.addToLabels(nonInboxLabel)

        try coreDataStack.saveViewContext()

        let handle = try await sendService.createOptimisticMessage(
            to: [recipient],
            body: "Failed reply",
            optimisticConversation: .participantHash(participantHash)
        )
        let optimisticMessage = try XCTUnwrap(sendService.fetchMessageSync(byID: handle.optimisticMessageID))
        XCTAssertNil(archivedConversation.archivedAt)
        XCTAssertFalse(archivedConversation.hidden)

        sendService.handleFailedOptimisticMessage(optimisticMessage)

        XCTAssertNil(sendService.fetchMessageSync(byID: handle.optimisticMessageID))
        XCTAssertEqual(archivedConversation.archivedAt, archivedAt)
        XCTAssertTrue(archivedConversation.hidden)
        XCTAssertEqual(archivedConversation.displayName, "Archived Thread")
        XCTAssertFalse(archivedConversation.hasInbox)
        XCTAssertEqual(archivedConversation.lastMessageDate, previousMessageDate)
        XCTAssertEqual(archivedConversation.snippet, "Previous received message")
    }

    func testHandleFailedOptimisticMessage_keepsNewerRemainingMessageRollupAndVisibility() async throws {
        let context = coreDataStack.viewContext
        let recipient = "newer-message-thread@example.com"
        let participantHash = calculateParticipantHash(from: [normalizedEmail(recipient)])
        let archivedAt = Date(timeIntervalSince1970: 300)
        let previousMessageDate = Date(timeIntervalSince1970: 250)

        let archivedConversation = ConversationBuilder()
            .withParticipantHash(participantHash)
            .withDisplayName("Thread With Newer Message")
            .withSnippet("Older received message")
            .withLastMessageDate(previousMessageDate)
            .hasInboxMessages(false)
            .archivedOn(archivedAt)
            .setHidden()
            .build(in: context)

        _ = MessageBuilder()
            .withId("older-received-message")
            .withDate(previousMessageDate)
            .withSnippet("Older received message")
            .inConversation(archivedConversation)
            .build(in: context)

        try coreDataStack.saveViewContext()

        let handle = try await sendService.createOptimisticMessage(
            to: [recipient],
            body: "Failed earlier reply",
            optimisticConversation: .participantHash(participantHash)
        )
        let optimisticMessage = try XCTUnwrap(sendService.fetchMessageSync(byID: handle.optimisticMessageID))
        let newerDate = optimisticMessage.internalDate.addingTimeInterval(10)
        let newerMessage = MessageBuilder()
            .withId("newer-remaining-message")
            .fromMe()
            .withDate(newerDate)
            .withSnippet("Newer reply remains")
            .inConversation(archivedConversation)
            .build(in: context)

        sendService.handleFailedOptimisticMessage(optimisticMessage)

        XCTAssertNil(sendService.fetchMessageSync(byID: handle.optimisticMessageID))
        XCTAssertNotNil(sendService.fetchMessageSync(byID: "newer-remaining-message"))
        XCTAssertNil(archivedConversation.archivedAt)
        XCTAssertFalse(archivedConversation.hidden)
        XCTAssertEqual(archivedConversation.lastMessageDate, newerDate)
        XCTAssertEqual(archivedConversation.snippet, newerMessage.conversationPreviewText)
    }

    func testHandleFailedOptimisticMessage_afterPersistedOptimisticUnarchive_restoresDurableConversationSnapshot() async throws {
        let context = coreDataStack.viewContext
        let recipient = "persisted-archived-thread@example.com"
        let participantHash = calculateParticipantHash(from: [normalizedEmail(recipient)])
        let archivedAt = Date(timeIntervalSince1970: 200)
        let previousMessageDate = Date(timeIntervalSince1970: 150)

        let archivedConversation = ConversationBuilder()
            .withParticipantHash(participantHash)
            .withDisplayName("Persisted Archived Thread")
            .withSnippet("Persisted previous message")
            .withLastMessageDate(previousMessageDate)
            .hasInboxMessages(false)
            .archivedOn(archivedAt)
            .setHidden()
            .build(in: context)

        let nonInboxLabel = LabelBuilder()
            .withId("CATEGORY_UPDATES")
            .withName("Updates")
            .build(in: context)
        let previousMessage = MessageBuilder()
            .withId("persisted-previous-received-message")
            .withDate(previousMessageDate)
            .withSnippet("Persisted previous message")
            .inConversation(archivedConversation)
            .build(in: context)
        previousMessage.addToLabels(nonInboxLabel)

        try coreDataStack.saveViewContext()

        let handle = try await sendService.createOptimisticMessage(
            to: [recipient],
            body: "Persisted failed reply",
            optimisticConversation: .participantHash(participantHash)
        )
        try coreDataStack.saveViewContext()
        coreDataStack.resetViewContext()

        let optimisticMessage = try XCTUnwrap(sendService.fetchMessageSync(byID: handle.optimisticMessageID))
        let persistedConversation = try XCTUnwrap(optimisticMessage.conversation)
        XCTAssertNil(persistedConversation.archivedAt)
        XCTAssertFalse(persistedConversation.hidden)
        XCTAssertEqual(try optimisticMutationRecordCount(in: context), 1)

        sendService.handleFailedOptimisticMessage(optimisticMessage)

        XCTAssertNil(sendService.fetchMessageSync(byID: handle.optimisticMessageID))
        XCTAssertEqual(persistedConversation.archivedAt, archivedAt)
        XCTAssertTrue(persistedConversation.hidden)
        XCTAssertEqual(persistedConversation.displayName, "Persisted Archived Thread")
        XCTAssertFalse(persistedConversation.hasInbox)
        XCTAssertEqual(persistedConversation.lastMessageDate, previousMessageDate)
        XCTAssertEqual(persistedConversation.snippet, "Persisted previous message")
        XCTAssertEqual(try optimisticMutationRecordCount(in: context), 0)
    }

    func testUpdateOptimisticMessage_retainsCommittedRouteUntilExactSync() async throws {
        let context = coreDataStack.viewContext
        let recipient = "success-clear@example.com"

        let handle = try await sendService.createOptimisticMessage(
            to: [recipient],
            body: "Send will succeed",
            optimisticConversation: .participantHash(
                calculateParticipantHash(from: [normalizedEmail(recipient)])
            )
        )
        let optimisticMessage = try XCTUnwrap(sendService.fetchMessageSync(byID: handle.optimisticMessageID))
        XCTAssertEqual(try optimisticMutationRecordCount(in: context), 1)

        sendService.updateOptimisticMessage(
            optimisticMessage,
            with: GmailSendService.SendResult(messageId: "gmail-success-id", threadId: "gmail-thread-id")
        )

        XCTAssertEqual(try optimisticMutationRecordCount(in: context), 1)
        let retained = try XCTUnwrap(
            sendService.fetchMessageSync(byID: handle.optimisticMessageID)
        )
        XCTAssertEqual(retained.gmThreadId, "gmail-thread-id")
        XCTAssertNil(sendService.fetchMessageSync(byID: "gmail-success-id"))
        let committed = try XCTUnwrap(
            sendService.remoteCommittedSendResult(
                optimisticMessageID: handle.optimisticMessageID
            )
        )
        XCTAssertEqual(committed.messageId, "gmail-success-id")
        XCTAssertEqual(committed.threadId, "gmail-thread-id")
    }

    func testRemoteCommittedSendResultReadsFreshStoreState() async throws {
        let context = coreDataStack.viewContext
        context.automaticallyMergesChangesFromParent = false

        let recipient = "fresh-remote-commit@example.com"
        let remoteResult = GmailSendService.SendResult(
            messageId: "gmail-fresh-remote-commit-id",
            threadId: "gmail-fresh-remote-thread-id"
        )

        let handle = try await sendService.createOptimisticMessage(
            to: [recipient],
            body: "Remote committed before retry",
            optimisticConversation: .participantHash(
                calculateParticipantHash(from: [normalizedEmail(recipient)])
            )
        )
        let staleRecord = try XCTUnwrap(
            optimisticMutationRecord(in: context, id: handle.optimisticMessageID)
        )
        XCTAssertNil(staleRecord.remoteCommittedMessageId)

        try sendService.recordRemoteCommittedSend(
            optimisticMessageID: handle.optimisticMessageID,
            result: remoteResult
        )

        XCTAssertNil(staleRecord.remoteCommittedMessageId)
        let committedResult = try XCTUnwrap(
            sendService.remoteCommittedSendResult(optimisticMessageID: handle.optimisticMessageID)
        )
        XCTAssertEqual(committedResult.messageId, remoteResult.messageId)
        XCTAssertEqual(committedResult.threadId, remoteResult.threadId)
    }

    func testRemoteCommitRefreshesRegisteredAdmissionMarkerWithoutPendingOverwrite() async throws {
        let context = coreDataStack.viewContext
        context.automaticallyMergesChangesFromParent = false
        let remoteResult = GmailSendService.SendResult(
            messageId: "gmail-after-admission-id",
            threadId: "gmail-after-admission-thread"
        )
        let recipient = "commit-after-admission@example.com"
        let handle = try await sendService.createOptimisticMessage(
            to: [recipient],
            body: "Keep the real commit durable",
            optimisticConversation: .participantHash(
                calculateParticipantHash(from: [normalizedEmail(recipient)])
            )
        )

        try sendService.recordRemoteSendAdmission(
            optimisticMessageID: handle.optimisticMessageID
        )
        let registeredRecord = try XCTUnwrap(
            optimisticMutationRecord(in: context, id: handle.optimisticMessageID)
        )
        XCTAssertEqual(
            registeredRecord.remoteCommittedMessageId,
            OutboundSendRemoteState.inFlightMessageID
        )
        XCTAssertFalse(context.hasChanges)

        try sendService.recordRemoteCommittedSend(
            optimisticMessageID: handle.optimisticMessageID,
            result: remoteResult
        )

        XCTAssertEqual(registeredRecord.remoteCommittedMessageId, remoteResult.messageId)
        XCTAssertEqual(registeredRecord.remoteCommittedThreadId, remoteResult.threadId)
        XCTAssertFalse(context.hasChanges)
        try coreDataStack.saveViewContext()
        coreDataStack.resetViewContext()

        let durableRecord = try XCTUnwrap(
            optimisticMutationRecord(in: context, id: handle.optimisticMessageID)
        )
        XCTAssertEqual(durableRecord.remoteCommittedMessageId, remoteResult.messageId)
        XCTAssertEqual(durableRecord.remoteCommittedThreadId, remoteResult.threadId)
    }

    func testReconcileAbandonedOptimisticSendMutations_remoteCommittedRecordWaitsForExactSync() async throws {
        let context = coreDataStack.viewContext
        let recipient = "remote-committed@example.com"
        let remoteResult = GmailSendService.SendResult(
            messageId: "gmail-remote-committed-id",
            threadId: "gmail-remote-thread-id"
        )

        let handle = try await sendService.createOptimisticMessage(
            to: [recipient],
            body: "Remote send already committed",
            optimisticConversation: .participantHash(
                calculateParticipantHash(from: [normalizedEmail(recipient)])
            )
        )
        XCTAssertNotNil(sendService.fetchMessageSync(byID: handle.optimisticMessageID))

        try sendService.recordRemoteCommittedSend(
            optimisticMessageID: handle.optimisticMessageID,
            result: remoteResult
        )

        sendService.reconcileAbandonedOptimisticSendMutations()

        let retained = try XCTUnwrap(
            sendService.fetchMessageSync(byID: handle.optimisticMessageID)
        )
        XCTAssertEqual(retained.gmThreadId, remoteResult.threadId)
        XCTAssertEqual(OutboundSendDeliveryState.resolve(for: retained), .none)
        XCTAssertNil(sendService.fetchMessageSync(byID: remoteResult.messageId))
        XCTAssertEqual(try optimisticMutationRecordCount(in: context), 1)
        XCTAssertEqual(try conversationCount(in: context), 1)
    }

    func testProductionServerAmbiguity_coldRecoveryRetainsOptimisticSendWithoutRetry() async throws {
        StubURLProtocol.reset()
        defer { StubURLProtocol.reset() }
        StubURLProtocol.script = [.status(500)]

        let authSession = AuthSession()
        authSession.userEmail = "sender@example.com"
        let productionAPIClient = GmailAPIClient(
            tokenManager: MockTokenManager(),
            retryStrategy: NetworkRetryStrategy(
                maxRetries: 3,
                initialDelay: 0.01,
                maxDelay: 0.02
            ),
            session: StubURLProtocol.makeSession()
        )
        let productionSendService = GmailSendService(
            viewContext: coreDataStack.viewContext,
            apiClient: productionAPIClient,
            authSession: authSession
        )
        let recipient = "ambiguous-cancellation@example.com"
        let handle = try await productionSendService.createOptimisticMessage(
            to: [recipient],
            body: "This send may already have reached Gmail",
            optimisticConversation: .participantHash(
                calculateParticipantHash(from: [normalizedEmail(recipient)])
            )
        )
        try coreDataStack.saveViewContext()

        let sendTask = ComposeSendOrchestrator(
            sendService: productionSendService,
            syncPerformer: NoOpIncrementalSyncPerformer()
        ).executeInBackground(
            input: .init(
                recipientEmails: [recipient],
                body: "This send may already have reached Gmail",
                htmlBody: nil,
                subject: "Ambiguous",
                attachmentInfos: [],
                inlineAttachmentInfos: [],
                replyMetadata: nil
            ),
            attachmentReferences: [],
            optimisticMessageID: handle.optimisticMessageID
        )
        await sendTask.task.value

        XCTAssertEqual(StubURLProtocol.requestCount, 1)
        XCTAssertNotNil(productionSendService.fetchMessageSync(byID: handle.optimisticMessageID))

        coreDataStack.resetViewContext()
        let coldStartAPIClient = MockGmailAPIClient()
        let coldStartSendService = GmailSendService(
            viewContext: coreDataStack.viewContext,
            apiClient: coldStartAPIClient
        )
        let durableRecord = try XCTUnwrap(
            optimisticMutationRecord(
                in: coreDataStack.viewContext,
                id: handle.optimisticMessageID
            )
        )
        XCTAssertNotNil(durableRecord.remoteCommittedMessageId)
        XCTAssertNil(durableRecord.remoteCommittedThreadId)

        coldStartSendService.reconcileAbandonedOptimisticSendMutations()

        XCTAssertNotNil(
            coldStartSendService.fetchMessageSync(byID: handle.optimisticMessageID),
            "Cold recovery must retain an ambiguous optimistic send rather than classify it as failed"
        )
        XCTAssertEqual(try optimisticMutationRecordCount(in: coreDataStack.viewContext), 1)
        XCTAssertEqual(coldStartAPIClient.sendMessageCallCount, 0)
    }

    func testInFlightSend_coldRecoveryConvertsDurableAdmissionToDeliveryUnknown() async throws {
        let recipient = "in-flight-crash-window@example.com"
        let handle = try await sendService.createOptimisticMessage(
            to: [recipient],
            body: "The response has not arrived yet",
            optimisticConversation: .participantHash(
                calculateParticipantHash(from: [normalizedEmail(recipient)])
            )
        )
        let gate = InFlightSendGate()
        let gatedSendService = InFlightComposeSendService(
            base: sendService,
            gate: gate
        )
        let sendTask = ComposeSendOrchestrator(
            sendService: gatedSendService,
            syncPerformer: NoOpIncrementalSyncPerformer()
        ).executeInBackground(
            input: .init(
                recipientEmails: [recipient],
                body: "The response has not arrived yet",
                htmlBody: nil,
                subject: "In flight",
                attachmentInfos: [],
                inlineAttachmentInfos: [],
                replyMetadata: nil
            ),
            attachmentReferences: [],
            optimisticMessageID: handle.optimisticMessageID
        )
        await gate.waitUntilStarted()
        try await sendTask.waitForTransmissionAdmission()

        // Simulate a fresh recovery session while messages.send is suspended
        // with no success or error response. The pre-send barrier must already
        // be durable, so recovery cannot classify this as definite failure.
        coreDataStack.resetViewContext()
        let coldStartSendService = GmailSendService(
            viewContext: coreDataStack.viewContext,
            apiClient: MockGmailAPIClient()
        )
        let durableRecord = try XCTUnwrap(
            optimisticMutationRecord(
                in: coreDataStack.viewContext,
                id: handle.optimisticMessageID
            )
        )
        XCTAssertEqual(
            durableRecord.remoteCommittedMessageId,
            OutboundSendRemoteState.inFlightMessageID
        )
        XCTAssertNil(durableRecord.remoteCommittedThreadId)

        coldStartSendService.reconcileAbandonedOptimisticSendMutations()

        XCTAssertNotNil(
            coldStartSendService.fetchMessageSync(byID: handle.optimisticMessageID)
        )
        XCTAssertEqual(
            try optimisticMutationRecord(
                in: coreDataStack.viewContext,
                id: handle.optimisticMessageID
            )?.remoteCommittedMessageId,
            OutboundSendRemoteState.ambiguousMessageID
        )
        XCTAssertEqual(try optimisticMutationRecordCount(in: coreDataStack.viewContext), 1)
        XCTAssertEqual(gatedSendService.sendCallCount, 1)

        await gate.release()
        await sendTask.task.value

        XCTAssertEqual(try optimisticMutationRecordCount(in: coreDataStack.viewContext), 1)
        let committedOptimistic = try XCTUnwrap(
            coldStartSendService.fetchMessageSync(byID: handle.optimisticMessageID)
        )
        XCTAssertEqual(committedOptimistic.gmThreadId, "gated-thread-id")
        XCTAssertNil(coldStartSendService.fetchMessageSync(byID: "gated-sent-id"))
        XCTAssertEqual(
            try optimisticMutationRecord(
                in: coreDataStack.viewContext,
                id: handle.optimisticMessageID
            )?.remoteCommittedMessageId,
            "gated-sent-id"
        )
    }

    func testCoordinatorReturn_hasDurableMessageAndSendingMarkerBeforeAPIResponse() async throws {
        let recipient = "admitted-before-response@example.com"
        let gate = InFlightSendGate()
        let apiClient = MockGmailAPIClient()
        apiClient.sendMessageOperation = { _, _ in
            await gate.waitUntilReleased()
            return SendMessageResponse(
                id: "admitted-sent-id",
                threadId: "admitted-thread-id"
            )
        }
        let authSession = AuthSession()
        authSession.userEmail = "me@example.com"
        let productionSendService = GmailSendService(
            viewContext: coreDataStack.viewContext,
            apiClient: apiClient,
            authSession: authSession
        )
        let outboundTaskRegistry = OutboundTaskRegistry(admissionOpen: true)
        let coordinator = OutboundMessageCoordinator(
            sendService: productionSendService,
            syncPerformer: NoOpIncrementalSyncPerformer(),
            messageFormatBuilder: MessageFormatBuilder(authSession: authSession),
            outboundReplyContextBuilder: OutboundReplyContextBuilder(
                viewContext: coreDataStack.viewContext,
                replyMetadataBuilder: ReplyMetadataBuilder(authSession: authSession),
                replyHTMLContentLoader: HTMLContentLoader(
                    contentHandler: HTMLContentHandler(),
                    sanitizer: .shared
                )
            ),
            mutationTracker: OutboundSendMutationTracker(),
            outboundTaskRegistry: outboundTaskRegistry
        )
        let successExpectation = expectation(description: "background send completes")

        let sendResult = try await coordinator.send(
            .compose(
                .init(
                    recipientEmails: [recipient],
                    subject: "Admitted",
                    body: "Durable before composer success",
                    attachments: []
                )
            ),
            reconciliationHooks: .init(
                onSuccess: { _ in successExpectation.fulfill() },
                onFailure: nil
            )
        )
        let submission = try XCTUnwrap(sendResult)
        await gate.waitUntilStarted()

        let durableRecord = try XCTUnwrap(
            durableMutationState(id: submission.optimisticMessageID)
        )
        XCTAssertEqual(
            durableRecord.remoteCommittedMessageId,
            OutboundSendRemoteState.inFlightMessageID
        )
        XCTAssertNil(durableRecord.remoteCommittedThreadId)
        XCTAssertNotNil(try durableMessageState(id: submission.optimisticMessageID))
        XCTAssertEqual(apiClient.sendMessageCallCount, 1)

        let inFlightMessage = try XCTUnwrap(
            productionSendService.fetchMessageSync(byID: submission.optimisticMessageID)
        )
        let deliveryState = OutboundSendDeliveryState.resolve(for: inFlightMessage)
        XCTAssertEqual(deliveryState, .sending)
        XCTAssertEqual(
            MessageSendStatusPresentation.resolve(
                deliveryState: deliveryState,
                isSendingLocalAttachments: false,
                hasFailedLocalAttachmentUploads: false
            ),
            .sending
        )

        await gate.release()
        await fulfillment(of: [successExpectation], timeout: 1.0)
        outboundTaskRegistry.closeAdmission()
        await outboundTaskRegistry.cancelAndAwaitAll()
    }

    func testSyncEchoConsumesMutationBeforeAPIResponse_successIsIdempotent() async throws {
        let recipient = "sync-first-race@example.com"
        let remoteMessageID = "gmail-sync-first-id"
        let remoteThreadID = "gmail-sync-first-thread"
        let gate = InFlightSendGate()
        let apiClient = MockGmailAPIClient()
        apiClient.sendMessageOperation = { _, _ in
            await gate.waitUntilReleased()
            return SendMessageResponse(id: remoteMessageID, threadId: remoteThreadID)
        }
        let authSession = AuthSession()
        authSession.userEmail = "me@example.com"
        let productionSendService = GmailSendService(
            viewContext: coreDataStack.viewContext,
            apiClient: apiClient,
            authSession: authSession
        )
        let handle = try await productionSendService.createOptimisticMessage(
            to: [recipient],
            body: "Sync wins before the API response",
            optimisticConversation: .participantHash(
                calculateParticipantHash(from: [normalizedEmail(recipient)])
            )
        )
        let sendOperation = ComposeSendOrchestrator(
            sendService: productionSendService,
            syncPerformer: NoOpIncrementalSyncPerformer()
        ).executeInBackground(
            input: .init(
                recipientEmails: [recipient],
                body: "Sync wins before the API response",
                htmlBody: nil,
                subject: "Race",
                attachmentInfos: [],
                inlineAttachmentInfos: [],
                replyMetadata: nil
            ),
            attachmentReferences: [],
            optimisticMessageID: handle.optimisticMessageID
        )

        await gate.waitUntilStarted()
        try await sendOperation.waitForTransmissionAdmission()

        let processedSentMessage = makeHeaderlessSentMessage(
            id: remoteMessageID,
            threadId: remoteThreadID,
            messageId: MimeBuilder.messageId(
                forOptimisticMessageID: handle.optimisticMessageID
            )
        )
        let syncContext = coreDataStack.newBackgroundContext()
        let isolatedCoreDataStack = CoreDataStack(
            persistentContainerForTesting: coreDataStack.persistentContainer
        )
        let persister = MessagePersister(
            coreDataStack: isolatedCoreDataStack,
            messageProcessor: StubRemoteSentMessageProcessor(
                processedMessage: processedSentMessage
            ),
            photoPrefetcher: { _ in }
        )
        try await persister.saveMessage(
            GmailMessage(
                id: remoteMessageID,
                threadId: remoteThreadID,
                labelIds: ["SENT"],
                snippet: processedSentMessage.snippet,
                historyId: nil,
                internalDate: nil,
                payload: nil,
                sizeEstimate: nil
            ),
            myAliases: ["me@example.com"],
            in: syncContext
        )
        try await syncContext.perform {
            try syncContext.save()
        }
        let viewContext = coreDataStack.viewContext
        viewContext.performAndWait {
            viewContext.refreshAllObjects()
        }

        XCTAssertEqual(try durableMutationRecordCount(), 0)
        XCTAssertNil(try durableMessageState(id: handle.optimisticMessageID))
        XCTAssertNotNil(try durableMessageState(id: remoteMessageID))

        await gate.release()
        await sendOperation.task.value

        XCTAssertEqual(apiClient.sendMessageCallCount, 1)
        XCTAssertEqual(try durableMutationRecordCount(), 0)
        XCTAssertNil(try durableMessageState(id: handle.optimisticMessageID))
        XCTAssertNotNil(try durableMessageState(id: remoteMessageID))
    }

    func testAPICommitAfterSyncStagesConsumptionBeforeSaveConvergesAtomically() async throws {
        let recipient = "api-reconcile-during-sync@example.com"
        let remoteMessageID = "gmail-api-reconcile-race-id"
        let remoteThreadID = "gmail-api-reconcile-race-thread"
        let handle = try await sendService.createOptimisticMessage(
            to: [recipient],
            body: "API success lands while sync is persisting the echo",
            optimisticConversation: .participantHash(
                calculateParticipantHash(from: [normalizedEmail(recipient)])
            )
        )
        try sendService.recordRemoteSendAdmission(
            optimisticMessageID: handle.optimisticMessageID
        )

        let processedSentMessage = makeHeaderlessSentMessage(
            id: remoteMessageID,
            threadId: remoteThreadID,
            messageId: MimeBuilder.messageId(
                forOptimisticMessageID: handle.optimisticMessageID
            )
        )
        let syncContext = coreDataStack.newBackgroundContext()
        let isolatedCoreDataStack = CoreDataStack(
            persistentContainerForTesting: coreDataStack.persistentContainer
        )
        let persister = MessagePersister(
            coreDataStack: isolatedCoreDataStack,
            photoPrefetcher: { _ in }
        )
        let sentRFCMessageID = try XCTUnwrap(
            processedSentMessage.headers.messageId
        )
        let capturedResolutions = try await persister.remoteCommittedSendMutationResolutions(
            for: [remoteMessageID],
            sentMessageIDsByRemoteID: [remoteMessageID: sentRFCMessageID],
            in: syncContext
        )
        let capturedResolution = try XCTUnwrap(capturedResolutions[remoteMessageID])

        // Sync has inserted the exact echo and staged deletion of both the
        // optimistic row and route, but its atomic context is not durable yet.
        try await persister.createNewMessage(
            processedSentMessage,
            labelIds: nil,
            myAliases: ["me@example.com"],
            modificationTransaction: nil,
            remoteCommittedSendMutation: capturedResolution,
            in: syncContext
        )
        let syncHasPendingReplacement = await syncContext.perform {
            syncContext.hasChanges
        }
        XCTAssertTrue(syncHasPendingReplacement)
        XCTAssertEqual(try durableMutationRecordCount(), 1)
        XCTAssertNotNil(try durableMessageState(id: handle.optimisticMessageID))
        XCTAssertNil(try durableMessageState(id: remoteMessageID))

        // The API response now lands in the old race window. It must retain the
        // graph/route rather than rename the row under sync's pending deletion.
        let sendResult = GmailSendService.SendResult(
            messageId: remoteMessageID,
            threadId: remoteThreadID
        )
        try sendService.recordRemoteCommittedSend(
            optimisticMessageID: handle.optimisticMessageID,
            result: sendResult
        )
        XCTAssertTrue(
            try sendService.reconcileRemoteCommittedSend(
                optimisticMessageID: handle.optimisticMessageID,
                result: sendResult
            )
        )
        XCTAssertEqual(try durableMutationRecordCount(), 1)
        XCTAssertNotNil(try durableMessageState(id: handle.optimisticMessageID))
        XCTAssertNil(try durableMessageState(id: remoteMessageID))

        try await syncContext.perform {
            try syncContext.save()
        }

        XCTAssertEqual(try durableMutationRecordCount(), 0)
        XCTAssertNil(try durableMessageState(id: handle.optimisticMessageID))
        XCTAssertNotNil(try durableMessageState(id: remoteMessageID))
        XCTAssertEqual(try durableMessageCount(id: remoteMessageID), 1)
    }

    func testExactSyncEchoHandsOffOptimisticAttachmentFilesBeforeDeletingGraph() async throws {
        let testID = UUID().uuidString
        let localAttachmentID = "local_echo_handoff_\(testID)"
        let remoteAttachmentID = "gmail-echo-handoff-attachment-\(testID)"
        let remoteMessageID = "gmail-echo-handoff-message-\(testID)"
        let remoteThreadID = "gmail-echo-handoff-thread-\(testID)"
        let filename = "echo-handoff.jpg"
        let originalData = Data("optimistic original attachment bytes".utf8)
        let previewData = Data("optimistic preview attachment bytes".utf8)
        let localOriginalPath = AttachmentPaths.originalPath(
            idOrUUID: localAttachmentID,
            ext: "jpg"
        )
        let localPreviewPath = AttachmentPaths.previewPath(idOrUUID: localAttachmentID)
        let remoteOriginalPath = AttachmentPaths.originalPath(
            messageId: remoteMessageID,
            attachmentId: remoteAttachmentID,
            ext: "jpg"
        )
        let remotePreviewPath = AttachmentPaths.previewPath(
            messageId: remoteMessageID,
            attachmentId: remoteAttachmentID
        )
        defer {
            AttachmentPaths.deleteFile(at: localOriginalPath)
            AttachmentPaths.deleteFile(at: localPreviewPath)
            AttachmentPaths.deleteFile(at: remoteOriginalPath)
            AttachmentPaths.deleteFile(at: remotePreviewPath)
        }

        AttachmentPaths.setupDirectories()
        XCTAssertTrue(AttachmentPaths.saveData(originalData, to: localOriginalPath))
        XCTAssertTrue(AttachmentPaths.saveData(previewData, to: localPreviewPath))

        let context = coreDataStack.viewContext
        let localAttachment = AttachmentBuilder()
            .withId(localAttachmentID)
            .asImage(width: 320, height: 180)
            .withFilename(filename)
            .withByteSize(Int64(originalData.count))
            .withLocalURL(localOriginalPath)
            .withPreviewURL(localPreviewPath)
            .downloaded()
            .build(in: context)
        let attachmentContexts = try OutboundAttachmentContextBuilder(
            viewContext: context
        ).buildSendAttachments(from: [localAttachment])
        let recipient = "echo-handoff@example.com"
        let handle = try await sendService.createOptimisticMessage(
            to: [recipient],
            body: "Preserve the attachment across exact echo convergence",
            attachments: attachmentContexts,
            optimisticConversation: .participantHash(
                calculateParticipantHash(from: [normalizedEmail(recipient)])
            )
        )
        try sendService.recordRemoteSendAdmission(
            optimisticMessageID: handle.optimisticMessageID
        )

        let activePreviewItem = try XCTUnwrap(
            AttachmentPreviewItem(attachment: localAttachment)
        )
        let activePreviewURL = try XCTUnwrap(activePreviewItem.previewItemURL)
        XCTAssertEqual(activePreviewURL, AttachmentPaths.fullURL(for: localOriginalPath))

        var processedSentMessage = makeHeaderlessSentMessage(
            id: remoteMessageID,
            threadId: remoteThreadID,
            messageId: MimeBuilder.messageId(
                forOptimisticMessageID: handle.optimisticMessageID
            )
        )
        processedSentMessage.hasAttachments = true
        processedSentMessage.attachmentInfo = [
            AttachmentInfo(
                id: remoteAttachmentID,
                filename: filename,
                mimeType: "image/jpeg",
                size: originalData.count,
                contentId: nil
            )
        ]

        let syncContext = coreDataStack.newBackgroundContext()
        let isolatedCoreDataStack = CoreDataStack(
            persistentContainerForTesting: coreDataStack.persistentContainer
        )
        let persister = MessagePersister(
            coreDataStack: isolatedCoreDataStack,
            photoPrefetcher: { _ in }
        )
        let sentRFCMessageID = try XCTUnwrap(processedSentMessage.headers.messageId)
        let resolutions = try await persister.remoteCommittedSendMutationResolutions(
            for: [remoteMessageID],
            sentMessageIDsByRemoteID: [remoteMessageID: sentRFCMessageID],
            in: syncContext
        )
        let resolution = try XCTUnwrap(resolutions[remoteMessageID])

        try await persister.createNewMessage(
            processedSentMessage,
            labelIds: nil,
            myAliases: ["me@example.com"],
            modificationTransaction: nil,
            remoteCommittedSendMutation: resolution,
            in: syncContext
        )

        let invalidationPlan = await syncContext.perform {
            CacheCoordinator.computeInvalidationPlan(
                updatedObjectIDs: Set(syncContext.updatedObjects.map(\.objectID)),
                deletedObjectIDs: Set(syncContext.deletedObjects.map(\.objectID)),
                in: syncContext
            )
        }
        XCTAssertFalse(invalidationPlan.attachmentPathsToDelete.contains(localOriginalPath))
        XCTAssertFalse(invalidationPlan.attachmentPathsToDelete.contains(localPreviewPath))
        XCTAssertFalse(invalidationPlan.attachmentPathsToDelete.contains(remoteOriginalPath))
        XCTAssertFalse(invalidationPlan.attachmentPathsToDelete.contains(remotePreviewPath))

        try await syncContext.perform {
            try syncContext.save()
        }

        let cacheCoordinator = CacheCoordinator()
        if let accountContext = cacheCoordinator.captureInvalidationAccountContext() {
            cacheCoordinator.applyInvalidationPlan(
                invalidationPlan,
                accountContext: accountContext
            )
            await Task.yield()
            await cacheCoordinator.closeAccountWorkAndAwait()
        }

        XCTAssertEqual(try durableMutationRecordCount(), 0)
        XCTAssertNil(try durableMessageState(id: handle.optimisticMessageID))
        XCTAssertEqual(try durableAttachmentCount(id: localAttachmentID), 0)
        XCTAssertEqual(try durableMessageCount(id: remoteMessageID), 1)

        let durableAttachment = try XCTUnwrap(
            durableAttachmentState(
                messageID: remoteMessageID,
                attachmentID: remoteAttachmentID
            )
        )
        XCTAssertEqual(durableAttachment.localURL, remoteOriginalPath)
        XCTAssertEqual(durableAttachment.previewURL, remotePreviewPath)
        XCTAssertEqual(durableAttachment.readableLocalURL, remoteOriginalPath)
        XCTAssertEqual(durableAttachment.readablePreviewURL, remotePreviewPath)
        XCTAssertEqual(durableAttachment.state, .downloaded)
        XCTAssertEqual(AttachmentPaths.loadData(from: remoteOriginalPath), originalData)
        XCTAssertEqual(AttachmentPaths.loadData(from: remotePreviewPath), previewData)

        XCTAssertTrue(FileManager.default.fileExists(atPath: activePreviewURL.path))
        XCTAssertEqual(try Data(contentsOf: activePreviewURL), originalData)
        XCTAssertEqual(AttachmentPaths.loadData(from: localPreviewPath), previewData)
        _ = activePreviewItem
    }

    func testColdRecovery_ambiguousSendConvergesOnExactSyncedMessageID() async throws {
        let recipient = "ambiguous-convergence@example.com"
        let handle = try await sendService.createOptimisticMessage(
            to: [recipient],
            body: "Ambiguous send that later arrives through sync",
            optimisticConversation: .participantHash(
                calculateParticipantHash(from: [normalizedEmail(recipient)])
            )
        )
        try sendService.persistOptimisticMessageBeforeTransmission(
            optimisticMessageID: handle.optimisticMessageID
        )
        try sendService.recordAmbiguousRemoteSend(
            optimisticMessageID: handle.optimisticMessageID
        )

        coreDataStack.resetViewContext()
        let coldStartSendService = GmailSendService(
            viewContext: coreDataStack.viewContext,
            apiClient: MockGmailAPIClient()
        )
        coldStartSendService.reconcileAbandonedOptimisticSendMutations()
        XCTAssertNotNil(
            coldStartSendService.fetchMessageSync(byID: handle.optimisticMessageID)
        )

        let remoteMessageID = "gmail-ambiguous-converged-id"
        let remoteThreadID = "gmail-ambiguous-converged-thread"
        let processedSentMessage = makeHeaderlessSentMessage(
            id: remoteMessageID,
            threadId: remoteThreadID,
            messageId: MimeBuilder.messageId(
                forOptimisticMessageID: handle.optimisticMessageID
            )
        )
        let syncContext = coreDataStack.newBackgroundContext()
        let isolatedCoreDataStack = CoreDataStack(
            persistentContainerForTesting: coreDataStack.persistentContainer
        )
        let persister = MessagePersister(
            coreDataStack: isolatedCoreDataStack,
            messageProcessor: StubRemoteSentMessageProcessor(
                processedMessage: processedSentMessage
            ),
            photoPrefetcher: { _ in }
        )
        try await persister.saveMessage(
            GmailMessage(
                id: remoteMessageID,
                threadId: remoteThreadID,
                labelIds: ["SENT"],
                snippet: processedSentMessage.snippet,
                historyId: nil,
                internalDate: nil,
                payload: nil,
                sizeEstimate: nil
            ),
            myAliases: ["me@example.com"],
            in: syncContext
        )

        // The marker and optimistic row remain durable until the real sent
        // message, duplicate cleanup, and marker consumption save atomically.
        XCTAssertEqual(try durableMutationRecordCount(), 1)
        XCTAssertNotNil(try durableMessageState(id: handle.optimisticMessageID))
        XCTAssertNil(try durableMessageState(id: remoteMessageID))

        try await syncContext.perform {
            try syncContext.save()
        }

        XCTAssertEqual(try durableMutationRecordCount(), 0)
        XCTAssertNil(try durableMessageState(id: handle.optimisticMessageID))
        XCTAssertNotNil(try durableMessageState(id: remoteMessageID))
    }

    func testColdRecovery_missingOptimisticListReplyRetainsRouteUntilSentSyncConsumesItAtomically() async throws {
        let context = coreDataStack.viewContext
        let listId = "list.example.com"
        let listConversation = ConversationBuilder()
            .asList()
            .withListId(listId)
            .withParticipantHash(
                calculateListConversationHash(fromNormalizedListId: listId)
            )
            .withDisplayName("Example List")
            .visible()
            .recentlyActive()
            .build(in: context)
        try coreDataStack.saveViewContext()
        let anchoredConversationID = listConversation.id
        let remoteResult = GmailSendService.SendResult(
            messageId: "gmail-cold-list-reply",
            threadId: "gmail-cold-list-thread"
        )

        let handle = try await sendService.createOptimisticMessage(
            to: ["post@list.example.com"],
            body: "Committed list reply",
            threadId: remoteResult.threadId,
            optimisticConversation: .existingConversation(
                ConversationReference(objectID: listConversation.objectID)
            )
        )
        try sendService.recordRemoteCommittedSend(
            optimisticMessageID: handle.optimisticMessageID,
            result: remoteResult
        )

        // Simulate a repaired/legacy store in which the committed mutation route
        // survived but its optimistic Message did not. New optimistic creation
        // persists both atomically, so this state is no longer a normal crash window.
        let optimisticMessage = try XCTUnwrap(
            sendService.fetchMessageSync(byID: handle.optimisticMessageID)
        )
        context.delete(optimisticMessage)
        try context.save()
        coreDataStack.resetViewContext()
        let coldStartSendService = GmailSendService(
            viewContext: coreDataStack.viewContext
        )
        XCTAssertNil(
            coldStartSendService.fetchMessageSync(byID: handle.optimisticMessageID)
        )

        coldStartSendService.reconcileAbandonedOptimisticSendMutations()

        XCTAssertEqual(try durableMutationRecordCount(), 1)
        XCTAssertNil(try durableMessageState(id: remoteResult.messageId))

        let processedSentMessage = makeHeaderlessSentMessage(
            id: remoteResult.messageId,
            threadId: remoteResult.threadId
        )
        let syncContext = coreDataStack.newBackgroundContext()
        let isolatedCoreDataStack = CoreDataStack(
            persistentContainerForTesting: coreDataStack.persistentContainer
        )
        let persister = MessagePersister(
            coreDataStack: isolatedCoreDataStack,
            messageProcessor: StubRemoteSentMessageProcessor(
                processedMessage: processedSentMessage
            ),
            photoPrefetcher: { _ in }
        )
        try await persister.saveMessage(
            GmailMessage(
                id: remoteResult.messageId,
                threadId: remoteResult.threadId,
                labelIds: ["SENT"],
                snippet: processedSentMessage.snippet,
                historyId: nil,
                internalDate: nil,
                payload: nil,
                sizeEstimate: nil
            ),
            myAliases: ["me@example.com"],
            in: syncContext
        )

        // The record deletion remains pending beside the routed Message.
        // Another process/context still sees the route until one atomic save.
        XCTAssertEqual(try durableMutationRecordCount(), 1)
        XCTAssertNil(try durableMessageState(id: remoteResult.messageId))

        try await syncContext.perform {
            try syncContext.save()
        }

        let durableMessage = try XCTUnwrap(
            durableMessageState(id: remoteResult.messageId)
        )
        XCTAssertEqual(durableMessage.conversationID, anchoredConversationID)
        XCTAssertEqual(durableMessage.listId, listId)
        XCTAssertEqual(durableMessage.conversationListId, listId)
        XCTAssertEqual(try durableMutationRecordCount(), 0)
    }

    func testColdRecovery_remoteListReplyAlreadyFetchedElsewhereRehomesBeforeClearingRoute() async throws {
        let context = coreDataStack.viewContext
        let listId = "list.example.com"
        let listConversation = ConversationBuilder()
            .asList()
            .withListId(listId)
            .withParticipantHash(
                calculateListConversationHash(fromNormalizedListId: listId)
            )
            .withDisplayName("Example List")
            .visible()
            .recentlyActive()
            .build(in: context)
        try coreDataStack.saveViewContext()
        let anchoredConversationID = listConversation.id
        let remoteResult = GmailSendService.SendResult(
            messageId: "gmail-prefetched-list-reply",
            threadId: "gmail-prefetched-list-thread"
        )

        let handle = try await sendService.createOptimisticMessage(
            to: ["post@list.example.com"],
            body: "Committed list reply",
            threadId: remoteResult.threadId,
            optimisticConversation: .existingConversation(
                ConversationReference(objectID: listConversation.objectID)
            )
        )
        try sendService.recordRemoteCommittedSend(
            optimisticMessageID: handle.optimisticMessageID,
            result: remoteResult
        )
        coreDataStack.resetViewContext()

        let wrongConversation = ConversationBuilder()
            .withParticipantHash(
                calculateParticipantHash(from: ["post@list.example.com"])
            )
            .withDisplayName("Wrong participant route")
            .withLastMessageDate(Date(timeIntervalSince1970: 1_700_000_100))
            .withSnippet("Committed list reply")
            .setPinned()
            .setMuted()
            .visible()
            .build(in: context)
        let remoteMessage = MessageBuilder()
            .withId(remoteResult.messageId)
            .withThreadId(remoteResult.threadId)
            .withDate(Date(timeIntervalSince1970: 1_700_000_100))
            .withSnippet("Committed list reply")
            .fromMe()
            .inConversation(wrongConversation)
            .build(in: context)
        try coreDataStack.saveViewContext()

        let coldStartSendService = GmailSendService(viewContext: context)
        coldStartSendService.reconcileAbandonedOptimisticSendMutations()

        XCTAssertEqual(remoteMessage.conversation?.id, anchoredConversationID)
        XCTAssertEqual(remoteMessage.listId, listId)
        XCTAssertEqual(remoteMessage.conversation?.listId, listId)
        XCTAssertTrue(remoteMessage.conversation?.pinned ?? false)
        XCTAssertTrue(remoteMessage.conversation?.muted ?? false)
        XCTAssertNil(wrongConversation.lastMessageDate)
        XCTAssertEqual(try optimisticMutationRecordCount(in: context), 0)
    }

    func testReconcileAbandonedOptimisticSendMutations_remoteMessageAlreadyFetchedDeletesOptimisticDuplicate() async throws {
        let context = coreDataStack.viewContext
        let recipient = "remote-fetched@example.com"
        let remoteResult = GmailSendService.SendResult(
            messageId: "gmail-already-fetched-id",
            threadId: "gmail-already-fetched-thread-id"
        )

        let handle = try await sendService.createOptimisticMessage(
            to: [recipient],
            body: "Remote send already committed and fetched",
            optimisticConversation: .participantHash(
                calculateParticipantHash(from: [normalizedEmail(recipient)])
            )
        )
        let optimisticMessage = try XCTUnwrap(sendService.fetchMessageSync(byID: handle.optimisticMessageID))
        let conversation = try XCTUnwrap(optimisticMessage.conversation)

        try sendService.recordRemoteCommittedSend(
            optimisticMessageID: handle.optimisticMessageID,
            result: remoteResult
        )
        _ = MessageBuilder()
            .withId(remoteResult.messageId)
            .withThreadId(remoteResult.threadId)
            .fromMe()
            .inConversation(conversation)
            .build(in: context)
        try coreDataStack.saveViewContext()

        sendService.reconcileAbandonedOptimisticSendMutations()

        XCTAssertNil(sendService.fetchMessageSync(byID: handle.optimisticMessageID))
        XCTAssertNotNil(sendService.fetchMessageSync(byID: remoteResult.messageId))
        XCTAssertEqual(try optimisticMutationRecordCount(in: context), 0)
        XCTAssertEqual(try messageCount(in: context), 1)
    }

    func testReconcileAbandonedOptimisticSendMutations_remoteMessageInDifferentConversationDeletesPersistedOptimisticConversation() async throws {
        let context = coreDataStack.viewContext
        let recipient = "remote-fetched-different-conversation@example.com"
        let participantHash = calculateParticipantHash(from: [normalizedEmail(recipient)])
        let remoteResult = GmailSendService.SendResult(
            messageId: "gmail-fetched-different-conversation-id",
            threadId: "gmail-fetched-different-conversation-thread-id"
        )

        let handle = try await sendService.createOptimisticMessage(
            to: [recipient],
            body: "Remote send fetched into another conversation",
            optimisticConversation: .participantHash(participantHash)
        )
        try coreDataStack.saveViewContext()

        try sendService.recordRemoteCommittedSend(
            optimisticMessageID: handle.optimisticMessageID,
            result: remoteResult
        )
        let fetchedConversation = ConversationBuilder()
            .withParticipantHash("remote-fetched-different-conversation-hash")
            .visible()
            .recentlyActive()
            .build(in: context)
        _ = MessageBuilder()
            .withId(remoteResult.messageId)
            .withThreadId(remoteResult.threadId)
            .fromMe()
            .inConversation(fetchedConversation)
            .build(in: context)
        try coreDataStack.saveViewContext()
        coreDataStack.resetViewContext()

        sendService.reconcileAbandonedOptimisticSendMutations()

        XCTAssertNil(sendService.fetchMessageSync(byID: handle.optimisticMessageID))
        XCTAssertNotNil(sendService.fetchMessageSync(byID: remoteResult.messageId))
        XCTAssertEqual(try optimisticMutationRecordCount(in: context), 0)
        XCTAssertEqual(try conversationCount(in: context), 1)
    }

    func testColdRecovery_nilRemoteStateRetainsMessageAsNotSent() async throws {
        let context = coreDataStack.viewContext
        let recipient = "abandoned-new-thread@example.com"
        let participantHash = calculateParticipantHash(from: [normalizedEmail(recipient)])

        let handle = try await sendService.createOptimisticMessage(
            to: [recipient],
            body: "Abandoned pending send",
            subject: "Preserved subject",
            optimisticConversation: .participantHash(participantHash)
        )
        coreDataStack.resetViewContext()

        XCTAssertNotNil(sendService.fetchMessageSync(byID: handle.optimisticMessageID))
        XCTAssertEqual(try conversationCount(in: context), 1)
        XCTAssertEqual(try optimisticMutationRecordCount(in: context), 1)

        sendService.reconcileAbandonedOptimisticSendMutations()

        let retainedMessage = try XCTUnwrap(
            sendService.fetchMessageSync(byID: handle.optimisticMessageID)
        )
        XCTAssertEqual(retainedMessage.bodyText, "Abandoned pending send")
        XCTAssertEqual(retainedMessage.subject, "Preserved subject")
        XCTAssertEqual(try conversationCount(in: context), 1)
        let record = try XCTUnwrap(
            optimisticMutationRecord(in: context, id: handle.optimisticMessageID)
        )
        XCTAssertEqual(
            record.remoteCommittedMessageId,
            OutboundSendRemoteState.notSentMessageID
        )
        XCTAssertNil(record.remoteCommittedThreadId)
    }

    func testColdRecovery_legacyNilStateStampsLocalIdentityAndShowsDeliveryUnknown() throws {
        let context = coreDataStack.viewContext
        let optimisticID = UUID().uuidString
        let conversation = ConversationBuilder()
            .withDisplayName("Legacy optimistic send")
            .visible()
            .recentlyActive()
            .build(in: context)
        let legacyMessage = MessageBuilder()
            .withId(optimisticID)
            .withBody("Preserve legacy authored text")
            .fromMe()
            .inConversation(conversation)
            .build(in: context)
        legacyMessage.messageId = nil
        try context.obtainPermanentIDs(for: [conversation, legacyMessage])
        let legacyRecord = context.insertTestObject(OutboundSendMutationRecord.self)
        legacyRecord.id = optimisticID
        legacyRecord.createdAt = Date()
        legacyRecord.conversationId = conversation.id
        legacyRecord.conversationURI = conversation.objectID.uriRepresentation().absoluteString
        legacyRecord.hidden = false
        legacyRecord.newlyInsertedConversation = false
        try context.save()

        coreDataStack.resetViewContext()
        let apiClient = MockGmailAPIClient()
        let coldStartSendService = GmailSendService(
            viewContext: context,
            apiClient: apiClient
        )
        coldStartSendService.reconcileAbandonedOptimisticSendMutations()

        let retained = try XCTUnwrap(
            coldStartSendService.fetchMessageSync(byID: optimisticID)
        )
        XCTAssertEqual(retained.bodyText, "Preserve legacy authored text")
        XCTAssertEqual(
            retained.messageIdValue,
            MimeBuilder.messageId(forOptimisticMessageID: optimisticID)
        )
        XCTAssertEqual(OutboundSendDeliveryState.resolve(for: retained), .deliveryUnknown)
        XCTAssertEqual(
            try optimisticMutationRecord(in: context, id: optimisticID)?
                .remoteCommittedMessageId,
            OutboundSendRemoteState.ambiguousMessageID
        )
        XCTAssertEqual(apiClient.sendMessageCallCount, 0)
    }

    func testRollbackBeforeTransmission_removesOptimisticBubbleAndRequeuesComposerAttachment() async throws {
        let context = coreDataStack.viewContext
        let attachment = AttachmentBuilder()
            .withId("local_preflight_rollback")
            .asImage()
            .queued()
            .withLocalURL("Attachments/preflight-rollback.jpg")
            .withPreviewURL("Previews/preflight-rollback.jpg")
            .build(in: context)
        let attachmentContexts = try OutboundAttachmentContextBuilder(
            viewContext: context
        ).buildSendAttachments(from: [attachment])
        let recipient = "preflight-rollback@example.com"
        let handle = try await sendService.createOptimisticMessage(
            to: [recipient],
            body: "Composer still owns this body",
            subject: "Composer still owns this subject",
            attachments: attachmentContexts,
            optimisticConversation: .participantHash(
                calculateParticipantHash(from: [normalizedEmail(recipient)])
            )
        )
        let reference = attachmentContexts[0].localAttachmentReference
        sendService.markAttachmentsAsUploading(references: [reference])

        XCTAssertEqual(attachment.message?.id, handle.optimisticMessageID)
        XCTAssertEqual(attachment.state, .uploading)

        sendService.rollbackOptimisticMessageBeforeTransmission(
            byID: handle.optimisticMessageID,
            fallbackAttachmentReferences: [reference]
        )

        XCTAssertNil(sendService.fetchMessageSync(byID: handle.optimisticMessageID))
        XCTAssertEqual(try optimisticMutationRecordCount(in: context), 0)
        XCTAssertEqual(try messageCount(in: context), 0)
        XCTAssertEqual(try conversationCount(in: context), 0)
        XCTAssertFalse(attachment.isDeleted)
        XCTAssertNil(attachment.message)
        XCTAssertEqual(attachment.state, .queued)
    }

    func testRetainDefinitelyUnsentOptimisticMessage_preservesBodySubjectAndAttachments() async throws {
        let context = coreDataStack.viewContext
        let attachment = AttachmentBuilder()
            .withId("local_definite_failure")
            .asImage()
            .queued()
            .withLocalURL("Attachments/definite-failure.jpg")
            .withPreviewURL("Previews/definite-failure.jpg")
            .build(in: context)
        let attachmentContexts = try OutboundAttachmentContextBuilder(viewContext: context)
            .buildSendAttachments(from: [attachment])
        let recipient = "definite-failure@example.com"
        let handle = try await sendService.createOptimisticMessage(
            to: [recipient],
            body: "Keep this authored body",
            subject: "Keep this subject",
            attachments: attachmentContexts,
            optimisticConversation: .participantHash(
                calculateParticipantHash(from: [normalizedEmail(recipient)])
            )
        )
        try sendService.recordRemoteSendAdmission(
            optimisticMessageID: handle.optimisticMessageID
        )

        sendService.retainDefinitelyUnsentOptimisticMessage(
            byID: handle.optimisticMessageID,
            fallbackAttachmentReferences: attachmentContexts.map(\.localAttachmentReference)
        )
        coreDataStack.resetViewContext()

        let retainedMessage = try XCTUnwrap(
            sendService.fetchMessageSync(byID: handle.optimisticMessageID)
        )
        XCTAssertEqual(retainedMessage.bodyText, "Keep this authored body")
        XCTAssertEqual(retainedMessage.subject, "Keep this subject")
        XCTAssertEqual(retainedMessage.attachmentsArray.map(\.id), ["local_definite_failure"])
        XCTAssertEqual(retainedMessage.attachmentsArray.first?.state, .failed)
        let record = try XCTUnwrap(
            optimisticMutationRecord(in: context, id: handle.optimisticMessageID)
        )
        XCTAssertEqual(
            record.remoteCommittedMessageId,
            OutboundSendRemoteState.notSentMessageID
        )
        XCTAssertNil(record.remoteCommittedThreadId)
    }

    func testColdRecovery_ambiguousMarkerStopsAttachmentSpinnerWithoutRetry() async throws {
        let context = coreDataStack.viewContext
        let attachment = AttachmentBuilder()
            .withId("local_ambiguous_attachment")
            .asImage()
            .queued()
            .withLocalURL("Attachments/ambiguous.jpg")
            .withPreviewURL("Previews/ambiguous.jpg")
            .build(in: context)
        let attachmentContexts = try OutboundAttachmentContextBuilder(viewContext: context)
            .buildSendAttachments(from: [attachment])
        let recipient = "ambiguous-attachment@example.com"
        let handle = try await sendService.createOptimisticMessage(
            to: [recipient],
            body: "Do not retry this ambiguous send",
            attachments: attachmentContexts,
            optimisticConversation: .participantHash(
                calculateParticipantHash(from: [normalizedEmail(recipient)])
            )
        )
        attachment.state = .uploading
        try context.save()
        try sendService.recordAmbiguousRemoteSend(
            optimisticMessageID: handle.optimisticMessageID
        )

        coreDataStack.resetViewContext()
        let apiClient = MockGmailAPIClient()
        let coldStartSendService = GmailSendService(
            viewContext: context,
            apiClient: apiClient
        )
        coldStartSendService.reconcileAbandonedOptimisticSendMutations()

        let retainedMessage = try XCTUnwrap(
            coldStartSendService.fetchMessageSync(byID: handle.optimisticMessageID)
        )
        XCTAssertFalse(retainedMessage.isSendingLocalAttachments)
        XCTAssertEqual(retainedMessage.attachmentsArray.first?.state, .uploaded)
        let record = try XCTUnwrap(
            optimisticMutationRecord(in: context, id: handle.optimisticMessageID)
        )
        XCTAssertEqual(
            record.remoteCommittedMessageId,
            OutboundSendRemoteState.ambiguousMessageID
        )
        XCTAssertEqual(apiClient.sendMessageCallCount, 0)
    }

    func testHandleFailedOptimisticMessage_withLocalAttachments_marksOnlyLocalAttachmentsFailed() throws {
        let context = coreDataStack.viewContext
        let conversation = ConversationBuilder()
            .withDisplayName("Active Thread")
            .visible()
            .recentlyActive()
            .build(in: context)

        let messageID = "optimistic-with-attachments"
        let message = MessageBuilder()
            .withId(messageID)
            .fromMe()
            .withAttachments()
            .inConversation(conversation)
            .build(in: context)

        let localAttachmentID = "local_attachment_1"
        _ = AttachmentBuilder()
            .withId(localAttachmentID)
            .downloading()
            .forMessage(message)
            .build(in: context)

        let remoteAttachmentID = "gmail_attachment_1"
        _ = AttachmentBuilder()
            .withId(remoteAttachmentID)
            .downloaded()
            .forMessage(message)
            .build(in: context)

        try coreDataStack.saveViewContext()

        sendService.handleFailedOptimisticMessage(message)

        let persisted = try XCTUnwrap(sendService.fetchMessageSync(byID: messageID))
        let localAttachment = try XCTUnwrap(persisted.attachmentsArray.first { $0.id == localAttachmentID })
        let remoteAttachment = try XCTUnwrap(persisted.attachmentsArray.first { $0.id == remoteAttachmentID })

        XCTAssertEqual(localAttachment.state, .failed)
        XCTAssertEqual(remoteAttachment.state, .downloaded)
        XCTAssertEqual(conversation.displayName, "Active Thread")
    }

    func testHandleFailedOptimisticMessage_withLocalAttachments_keepsFailedBubbleAndRecomputesRollup() async throws {
        let context = coreDataStack.viewContext
        let attachmentBuilder = OutboundAttachmentContextBuilder(viewContext: context)
        let attachment = AttachmentBuilder()
            .withId("local_attachment_rollup")
            .asImage()
            .queued()
            .withLocalURL("Attachments/photo.jpg")
            .withPreviewURL("Previews/photo.jpg")
            .build(in: context)

        let handle = try await sendService.createOptimisticMessage(
            to: ["attachment-failure@example.com"],
            body: "Failed attachment body",
            attachments: try attachmentBuilder.buildSendAttachments(from: [attachment]),
            optimisticConversation: .participantHash(
                calculateParticipantHash(from: [normalizedEmail("attachment-failure@example.com")])
            )
        )

        let message = try XCTUnwrap(sendService.fetchMessageSync(byID: handle.optimisticMessageID))
        let messageDate = message.internalDate

        sendService.handleFailedOptimisticMessage(message)

        let persisted = try XCTUnwrap(sendService.fetchMessageSync(byID: handle.optimisticMessageID))
        let persistedConversation = try XCTUnwrap(persisted.conversation)
        let persistedAttachment = try XCTUnwrap(persisted.attachmentsArray.first)

        XCTAssertEqual(persistedAttachment.state, .failed)
        XCTAssertEqual(persistedConversation.lastMessageDate, messageDate)
        XCTAssertEqual(persistedConversation.snippet, persisted.conversationPreviewText)
        XCTAssertFalse(persistedConversation.hasInbox)
        XCTAssertEqual(persistedConversation.inboxUnreadCount, 0)
        XCTAssertNil(persistedConversation.latestInboxDate)
        XCTAssertNil(persistedConversation.archivedAt)
        XCTAssertFalse(persistedConversation.hidden)
        XCTAssertEqual(try conversationCount(in: context), 1)
    }

    private func conversationCount(in context: NSManagedObjectContext) throws -> Int {
        let request = Conversation.fetchRequest()
        request.includesPendingChanges = true
        return try context.count(for: request)
    }

    private func optimisticMutationRecordCount(in context: NSManagedObjectContext) throws -> Int {
        let request = OutboundSendMutationRecord.fetchRequest()
        request.includesPendingChanges = true
        return try context.count(for: request)
    }

    private func optimisticMutationRecord(
        in context: NSManagedObjectContext,
        id: String
    ) throws -> OutboundSendMutationRecord? {
        let request = OutboundSendMutationRecord.fetchRequest()
        request.predicate = NSPredicate(format: "id == %@", id)
        request.fetchLimit = 1
        request.includesPendingChanges = true
        return try context.fetch(request).first
    }

    private func messageCount(in context: NSManagedObjectContext) throws -> Int {
        let request = Message.fetchRequest()
        request.includesPendingChanges = true
        return try context.count(for: request)
    }

    private struct DurableMessageState {
        let listId: String?
        let conversationID: UUID?
        let conversationListId: String?
    }

    private struct DurableMutationState {
        let remoteCommittedMessageId: String?
        let remoteCommittedThreadId: String?
    }

    private struct DurableAttachmentState {
        let localURL: String?
        let previewURL: String?
        let readableLocalURL: String?
        let readablePreviewURL: String?
        let state: Attachment.State
    }

    private func durableMutationRecordCount() throws -> Int {
        let verificationContext = coreDataStack.newBackgroundContext()
        return try verificationContext.performAndWait {
            let request = OutboundSendMutationRecord.fetchRequest()
            request.includesPendingChanges = false
            return try verificationContext.count(for: request)
        }
    }

    private func durableMutationState(id: String) throws -> DurableMutationState? {
        let verificationContext = coreDataStack.newBackgroundContext()
        return try verificationContext.performAndWait {
            let request = OutboundSendMutationRecord.fetchRequest()
            request.predicate = NSPredicate(format: "id == %@", id)
            request.fetchLimit = 1
            request.includesPendingChanges = false
            guard let record = try verificationContext.fetch(request).first else {
                return nil
            }
            return DurableMutationState(
                remoteCommittedMessageId: record.remoteCommittedMessageId,
                remoteCommittedThreadId: record.remoteCommittedThreadId
            )
        }
    }

    private func durableMessageState(id: String) throws -> DurableMessageState? {
        let verificationContext = coreDataStack.newBackgroundContext()
        return try verificationContext.performAndWait {
            let request = Message.fetchRequest()
            request.predicate = MessagePredicates.id(id)
            request.fetchLimit = 1
            request.relationshipKeyPathsForPrefetching = ["conversation"]
            guard let message = try verificationContext.fetch(request).first else {
                return nil
            }
            return DurableMessageState(
                listId: message.listId,
                conversationID: message.conversation?.id,
                conversationListId: message.conversation?.listId
            )
        }
    }

    private func durableMessageCount(id: String) throws -> Int {
        let verificationContext = coreDataStack.newBackgroundContext()
        return try verificationContext.performAndWait {
            let request = Message.fetchRequest()
            request.predicate = MessagePredicates.id(id)
            request.includesPendingChanges = false
            return try verificationContext.count(for: request)
        }
    }

    private func durableAttachmentState(
        messageID: String,
        attachmentID: String
    ) throws -> DurableAttachmentState? {
        let verificationContext = coreDataStack.newBackgroundContext()
        return try verificationContext.performAndWait {
            let request = Message.fetchRequest()
            request.predicate = MessagePredicates.id(messageID)
            request.fetchLimit = 1
            request.relationshipKeyPathsForPrefetching = ["attachments"]
            guard let message = try verificationContext.fetch(request).first,
                  let attachment = message.attachmentsArray.first(where: {
                      $0.id == attachmentID
                  }) else {
                return nil
            }
            return DurableAttachmentState(
                localURL: attachment.localURL,
                previewURL: attachment.previewURL,
                readableLocalURL: attachment.readableLocalURLValue,
                readablePreviewURL: attachment.readablePreviewURLValue,
                state: attachment.state
            )
        }
    }

    private func durableAttachmentCount(id: String) throws -> Int {
        let verificationContext = coreDataStack.newBackgroundContext()
        return try verificationContext.performAndWait {
            let request = Attachment.fetchRequest()
            request.predicate = NSPredicate(format: "id == %@", id)
            request.includesPendingChanges = false
            return try verificationContext.count(for: request)
        }
    }

    private func makeHeaderlessSentMessage(
        id: String,
        threadId: String,
        messageId: String? = nil
    ) -> ProcessedMessage {
        var headers = ProcessedHeaders()
        headers.subject = "Re: List topic"
        headers.from = "Me <me@example.com>"
        headers.to = [
            EmailAddress(email: "post@list.example.com", displayName: nil)
        ]
        headers.isFromMe = true
        headers.listId = nil
        headers.messageId = messageId

        var processedMessage = ProcessedMessage()
        processedMessage.id = id
        processedMessage.gmThreadId = threadId
        processedMessage.snippet = "Committed list reply"
        processedMessage.cleanedSnippet = "Committed list reply"
        processedMessage.chatPreviewText = "Committed list reply"
        processedMessage.internalDate = Date(timeIntervalSince1970: 1_700_000_000)
        processedMessage.headers = headers
        processedMessage.plainTextBody = "Committed list reply"
        processedMessage.labelIds = ["SENT"]
        return processedMessage
    }
}

@MainActor
private final class NoOpIncrementalSyncPerformer: IncrementalSyncPerforming {
    func performIncrementalSync() async throws {}
}

private actor InFlightSendGate {
    private var started = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func waitUntilReleased() async {
        started = true
        let waiters = startWaiters
        startWaiters.removeAll()
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
        releaseWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }
}

private final class InFlightComposeSendService: ComposeSendServicing, @unchecked Sendable {
    private let base: GmailSendService
    private let gate: InFlightSendGate
    private let lock = NSLock()
    private var _sendCallCount = 0

    init(base: GmailSendService, gate: InFlightSendGate) {
        self.base = base
        self.gate = gate
    }

    var sendCallCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return _sendCallCount
    }

    @MainActor
    func markAttachmentsAsUploaded(references: [LocalAttachmentReference]) {
        base.markAttachmentsAsUploaded(references: references)
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
        try await beforeTransmission()
        await waitForResponse()
        return .init(messageId: "gated-sent-id", threadId: threadId)
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
        try await beforeTransmission()
        await waitForResponse()
        return .init(messageId: "gated-sent-id", threadId: "gated-thread-id")
    }

    @MainActor
    func remoteCommittedSendResult(optimisticMessageID: String) -> GmailSendService.SendResult? {
        base.remoteCommittedSendResult(optimisticMessageID: optimisticMessageID)
    }

    @MainActor
    func persistOptimisticMessageBeforeTransmission(optimisticMessageID: String) throws {
        try base.persistOptimisticMessageBeforeTransmission(
            optimisticMessageID: optimisticMessageID
        )
    }

    @MainActor
    func recordRemoteSendAdmission(optimisticMessageID: String) throws {
        try base.recordRemoteSendAdmission(optimisticMessageID: optimisticMessageID)
    }

    @MainActor
    func recordAmbiguousRemoteSend(optimisticMessageID: String) throws {
        try base.recordAmbiguousRemoteSend(optimisticMessageID: optimisticMessageID)
    }

    @MainActor
    func recordRemoteCommittedSend(
        optimisticMessageID: String,
        result: GmailSendService.SendResult
    ) throws {
        try base.recordRemoteCommittedSend(
            optimisticMessageID: optimisticMessageID,
            result: result
        )
    }

    @MainActor
    func reconcileRemoteCommittedSend(
        optimisticMessageID: String,
        result: GmailSendService.SendResult
    ) throws -> Bool {
        try base.reconcileRemoteCommittedSend(
            optimisticMessageID: optimisticMessageID,
            result: result
        )
    }

    @MainActor
    func rollbackOptimisticMessageBeforeTransmission(
        byID messageID: String,
        fallbackAttachmentReferences: [LocalAttachmentReference]
    ) {
        base.rollbackOptimisticMessageBeforeTransmission(
            byID: messageID,
            fallbackAttachmentReferences: fallbackAttachmentReferences
        )
    }

    @MainActor
    func retainDefinitelyUnsentOptimisticMessage(
        byID messageID: String,
        fallbackAttachmentReferences: [LocalAttachmentReference]
    ) {
        base.retainDefinitelyUnsentOptimisticMessage(
            byID: messageID,
            fallbackAttachmentReferences: fallbackAttachmentReferences
        )
    }

    private func waitForResponse() async {
        recordSendStarted()
        await gate.waitUntilReleased()
    }

    private func recordSendStarted() {
        lock.lock()
        _sendCallCount += 1
        lock.unlock()
    }
}

private final class StubRemoteSentMessageProcessor: MessageProcessor, @unchecked Sendable {
    private let processedMessage: ProcessedMessage

    init(processedMessage: ProcessedMessage) {
        self.processedMessage = processedMessage
    }

    override func processGmailMessage(
        _ gmailMessage: GmailMessage,
        myAliases: Set<String>,
        sendAsAliases: [SendAsAlias] = []
    ) async -> ProcessedMessage? {
        processedMessage
    }
}
