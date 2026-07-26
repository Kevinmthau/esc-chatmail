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
        XCTAssertTrue(conversation.isInserted)
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

    func testUpdateOptimisticMessage_clearsDurableMutationRecordOnSuccess() async throws {
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

        XCTAssertEqual(try optimisticMutationRecordCount(in: context), 0)
        XCTAssertNotNil(sendService.fetchMessageSync(byID: "gmail-success-id"))
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

    func testReconcileAbandonedOptimisticSendMutations_remoteCommittedRecordReconcilesWithoutFailureCleanup() async throws {
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

        XCTAssertNil(sendService.fetchMessageSync(byID: handle.optimisticMessageID))
        let reconciled = try XCTUnwrap(sendService.fetchMessageSync(byID: remoteResult.messageId))
        XCTAssertEqual(reconciled.gmThreadId, remoteResult.threadId)
        XCTAssertEqual(try optimisticMutationRecordCount(in: context), 0)
        XCTAssertEqual(try conversationCount(in: context), 1)
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

        // Exact process-death window: the mutation record is durable, while
        // the optimistic Message (including its inherited List-Id) is not.
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
        await persister.saveMessage(
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

    func testReconcileAbandonedOptimisticSendMutations_deletesPersistedNewEmptyConversation() async throws {
        let context = coreDataStack.viewContext
        let recipient = "abandoned-new-thread@example.com"
        let participantHash = calculateParticipantHash(from: [normalizedEmail(recipient)])

        let handle = try await sendService.createOptimisticMessage(
            to: [recipient],
            body: "Abandoned pending send",
            optimisticConversation: .participantHash(participantHash)
        )
        try coreDataStack.saveViewContext()
        coreDataStack.resetViewContext()

        XCTAssertNotNil(sendService.fetchMessageSync(byID: handle.optimisticMessageID))
        XCTAssertEqual(try conversationCount(in: context), 1)
        XCTAssertEqual(try optimisticMutationRecordCount(in: context), 1)

        sendService.reconcileAbandonedOptimisticSendMutations()

        XCTAssertNil(sendService.fetchMessageSync(byID: handle.optimisticMessageID))
        XCTAssertEqual(try conversationCount(in: context), 0)
        XCTAssertEqual(try optimisticMutationRecordCount(in: context), 0)
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

    private func durableMutationRecordCount() throws -> Int {
        let verificationContext = coreDataStack.newBackgroundContext()
        return try verificationContext.performAndWait {
            let request = OutboundSendMutationRecord.fetchRequest()
            request.includesPendingChanges = false
            return try verificationContext.count(for: request)
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

    private func makeHeaderlessSentMessage(
        id: String,
        threadId: String
    ) -> ProcessedMessage {
        var headers = ProcessedHeaders()
        headers.subject = "Re: List topic"
        headers.from = "Me <me@example.com>"
        headers.to = [
            EmailAddress(email: "post@list.example.com", displayName: nil)
        ]
        headers.isFromMe = true
        headers.listId = nil

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
