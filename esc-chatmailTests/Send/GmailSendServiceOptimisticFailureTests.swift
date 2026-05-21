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

    private func messageCount(in context: NSManagedObjectContext) throws -> Int {
        let request = Message.fetchRequest()
        request.includesPendingChanges = true
        return try context.count(for: request)
    }
}
