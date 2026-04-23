import XCTest
import CoreData
@testable import esc_chatmail

final class BackgroundMessageProcessorTests: XCTestCase {
    func testBuildChangeSet_includesMessagesFromLabelChanges() {
        let record = HistoryRecord(
            id: "h1",
            messages: nil,
            messagesAdded: nil,
            messagesDeleted: nil,
            labelsAdded: [
                HistoryLabelAdded(
                    message: MessageListItem(id: "m-label-add", threadId: nil),
                    labelIds: ["UNREAD"]
                )
            ],
            labelsRemoved: [
                HistoryLabelRemoved(
                    message: MessageListItem(id: "m-label-remove", threadId: nil),
                    labelIds: ["INBOX"]
                )
            ]
        )

        let changeSet = BackgroundMessageProcessor.buildChangeSet(from: [record])

        XCTAssertEqual(
            changeSet.messageIdsToFetch,
            Set(["m-label-add", "m-label-remove"])
        )
        XCTAssertTrue(changeSet.messageIdsToDelete.isEmpty)
    }

    func testBuildChangeSet_skipsExcludedMailboxMessagesAdded() {
        let spamMessage = GmailMessage(
            id: "m-spam",
            threadId: nil,
            labelIds: ["SPAM"],
            snippet: nil,
            historyId: nil,
            internalDate: nil,
            payload: nil,
            sizeEstimate: nil
        )
        let draftMessage = GmailMessage(
            id: "m-draft",
            threadId: nil,
            labelIds: ["DRAFT"],
            snippet: nil,
            historyId: nil,
            internalDate: nil,
            payload: nil,
            sizeEstimate: nil
        )
        let trashMessage = GmailMessage(
            id: "m-trash",
            threadId: nil,
            labelIds: ["TRASH"],
            snippet: nil,
            historyId: nil,
            internalDate: nil,
            payload: nil,
            sizeEstimate: nil
        )
        let normalMessage = GmailMessage(
            id: "m-normal",
            threadId: nil,
            labelIds: ["INBOX"],
            snippet: nil,
            historyId: nil,
            internalDate: nil,
            payload: nil,
            sizeEstimate: nil
        )

        let record = HistoryRecord(
            id: "h2",
            messages: nil,
            messagesAdded: [
                HistoryMessageAdded(message: spamMessage),
                HistoryMessageAdded(message: draftMessage),
                HistoryMessageAdded(message: trashMessage),
                HistoryMessageAdded(message: normalMessage)
            ],
            messagesDeleted: nil,
            labelsAdded: nil,
            labelsRemoved: nil
        )

        let changeSet = BackgroundMessageProcessor.buildChangeSet(from: [record])

        XCTAssertEqual(changeSet.messageIdsToFetch, Set(["m-normal"]))
        XCTAssertFalse(changeSet.messageIdsToFetch.contains("m-spam"))
        XCTAssertFalse(changeSet.messageIdsToFetch.contains("m-draft"))
        XCTAssertFalse(changeSet.messageIdsToFetch.contains("m-trash"))
    }

    func testBuildChangeSet_deletionsTakePrecedenceOverFetches() {
        let addedMessage = GmailMessage(
            id: "m1",
            threadId: nil,
            labelIds: ["INBOX"],
            snippet: nil,
            historyId: nil,
            internalDate: nil,
            payload: nil,
            sizeEstimate: nil
        )

        let record = HistoryRecord(
            id: "h3",
            messages: nil,
            messagesAdded: [HistoryMessageAdded(message: addedMessage)],
            messagesDeleted: [HistoryMessageDeleted(message: MessageListItem(id: "m1", threadId: nil))],
            labelsAdded: [HistoryLabelAdded(message: MessageListItem(id: "m1", threadId: nil), labelIds: ["UNREAD"])],
            labelsRemoved: nil
        )

        let changeSet = BackgroundMessageProcessor.buildChangeSet(from: [record])

        XCTAssertEqual(changeSet.messageIdsToDelete, Set(["m1"]))
        XCTAssertFalse(changeSet.messageIdsToFetch.contains("m1"))
    }

    func testProcessHistoryChanges_usesSingleContextForDeleteFetchAndRollups() async throws {
        let stack = TestCoreDataStack()
        let seedConversation = ConversationBuilder.simple(in: stack.viewContext)
        _ = MessageBuilder()
            .withId("delete-me")
            .withThreadId("thread-delete")
            .inConversation(seedConversation)
            .build(in: stack.viewContext)
        try stack.saveViewContext()

        let apiClient = MockGmailAPIClient()
        apiClient.addMessage(
            GmailMessage(
                id: "fetch-me",
                threadId: "thread-fetch",
                labelIds: ["INBOX"],
                snippet: "Fetched in background",
                historyId: "h1",
                internalDate: nil,
                payload: nil,
                sizeEstimate: nil
            )
        )

        let syncCoordinator = MockBackgroundSyncCoordinator(
            seedConversationObjectID: seedConversation.objectID
        )
        let processor = BackgroundMessageProcessor(
            makeBackgroundContext: { stack.newBackgroundContext() },
            saveContext: { stack.saveIfNeeded(context: $0) },
            apiClient: apiClient,
            syncCoordinator: syncCoordinator
        )

        let history = HistoryRecord(
            id: "history-1",
            messages: nil,
            messagesAdded: [
                HistoryMessageAdded(
                    message: GmailMessage(
                        id: "fetch-me",
                        threadId: "thread-fetch",
                        labelIds: ["INBOX"],
                        snippet: "Fetched in background",
                        historyId: "h1",
                        internalDate: nil,
                        payload: nil,
                        sizeEstimate: nil
                    )
                )
            ],
            messagesDeleted: [
                HistoryMessageDeleted(message: MessageListItem(id: "delete-me", threadId: nil))
            ],
            labelsAdded: nil,
            labelsRemoved: nil
        )

        let backgroundContext = stack.newBackgroundContext()
        let result = await processor.processHistoryChanges(histories: [history], in: backgroundContext)

        let verificationContext = stack.newBackgroundContext()
        let deletedMessage = await verificationContext.perform {
            try? verificationContext.fetchMessage(byId: "delete-me")
        }
        let fetchedMessage = await verificationContext.perform {
            try? verificationContext.fetchMessage(byId: "fetch-me")
        }

        XCTAssertNil(deletedMessage)
        XCTAssertEqual(fetchedMessage?.id, "fetch-me")
        XCTAssertEqual(apiClient.getMessageCalledIds, ["fetch-me"])
        XCTAssertEqual(syncCoordinator.prefetchContextIDs, [ObjectIdentifier(backgroundContext)])
        XCTAssertEqual(syncCoordinator.savedMessageContextIDs, [ObjectIdentifier(backgroundContext)])
        XCTAssertEqual(
            syncCoordinator.rollupContextIDs,
            [ObjectIdentifier(backgroundContext), ObjectIdentifier(backgroundContext)]
        )
        XCTAssertEqual(
            syncCoordinator.rollupConversationIDs,
            [Set([seedConversation.objectID]), Set([seedConversation.objectID])]
        )
        XCTAssertEqual(result, BackgroundMessageProcessingResult(fetchedCount: 1, failedFetchCount: 0))
    }

    func testProcessHistoryChanges_persistsDeletionsWhenFetchedMessageSaveFails() async throws {
        let stack = TestCoreDataStack()
        let seedConversation = ConversationBuilder.simple(in: stack.viewContext)
        _ = MessageBuilder()
            .withId("delete-me")
            .withThreadId("thread-delete")
            .inConversation(seedConversation)
            .build(in: stack.viewContext)
        try stack.saveViewContext()

        let apiClient = MockGmailAPIClient()
        apiClient.addMessage(
            GmailMessage(
                id: "fetch-me",
                threadId: "thread-fetch",
                labelIds: ["INBOX"],
                snippet: "Fetched in background",
                historyId: "h1",
                internalDate: nil,
                payload: nil,
                sizeEstimate: nil
            )
        )

        let syncCoordinator = MockBackgroundSyncCoordinator(
            seedConversationObjectID: seedConversation.objectID
        )
        let saveRecorder = BackgroundSaveRecorder(stack: stack, failWhenUnsavedMessageIDExists: "fetch-me")
        let processor = BackgroundMessageProcessor(
            makeBackgroundContext: { stack.newBackgroundContext() },
            saveContext: { saveRecorder.save(context: $0) },
            apiClient: apiClient,
            syncCoordinator: syncCoordinator
        )

        let history = HistoryRecord(
            id: "history-2",
            messages: nil,
            messagesAdded: [
                HistoryMessageAdded(
                    message: GmailMessage(
                        id: "fetch-me",
                        threadId: "thread-fetch",
                        labelIds: ["INBOX"],
                        snippet: "Fetched in background",
                        historyId: "h1",
                        internalDate: nil,
                        payload: nil,
                        sizeEstimate: nil
                    )
                )
            ],
            messagesDeleted: [
                HistoryMessageDeleted(message: MessageListItem(id: "delete-me", threadId: nil))
            ],
            labelsAdded: nil,
            labelsRemoved: nil
        )

        let backgroundContext = stack.newBackgroundContext()
        let result = await processor.processHistoryChanges(histories: [history], in: backgroundContext)

        let verificationContext = stack.newBackgroundContext()
        let deletedMessage = await verificationContext.perform {
            try? verificationContext.fetchMessage(byId: "delete-me")
        }
        let fetchedMessage = await verificationContext.perform {
            try? verificationContext.fetchMessage(byId: "fetch-me")
        }

        XCTAssertNil(deletedMessage)
        XCTAssertNil(fetchedMessage)
        XCTAssertEqual(saveRecorder.callCount, 2)
        XCTAssertEqual(syncCoordinator.prefetchContextIDs, [ObjectIdentifier(backgroundContext)])
        XCTAssertEqual(syncCoordinator.savedMessageContextIDs, [ObjectIdentifier(backgroundContext)])
        XCTAssertEqual(syncCoordinator.rollupContextIDs, [ObjectIdentifier(backgroundContext)])
        XCTAssertEqual(syncCoordinator.rollupConversationIDs, [Set([seedConversation.objectID])])
        XCTAssertEqual(result, BackgroundMessageProcessingResult(fetchedCount: 1, failedFetchCount: 1))
    }

    func testProcessHistoryChanges_returnsFailedFetchCountWhenMessageFetchFails() async throws {
        let stack = TestCoreDataStack()
        let seedConversation = ConversationBuilder.simple(in: stack.viewContext)
        try stack.saveViewContext()

        let apiClient = MockGmailAPIClient()
        apiClient.addMessage(
            GmailMessage(
                id: "fetch-ok",
                threadId: "thread-fetch-ok",
                labelIds: ["INBOX"],
                snippet: "Fetched in background",
                historyId: "h1",
                internalDate: nil,
                payload: nil,
                sizeEstimate: nil
            )
        )
        apiClient.getMessageErrors["fetch-fail"] = APIError.timeout

        let syncCoordinator = MockBackgroundSyncCoordinator(
            seedConversationObjectID: seedConversation.objectID
        )
        let processor = BackgroundMessageProcessor(
            makeBackgroundContext: { stack.newBackgroundContext() },
            saveContext: { stack.saveIfNeeded(context: $0) },
            apiClient: apiClient,
            syncCoordinator: syncCoordinator
        )

        let history = HistoryRecord(
            id: "history-failures",
            messages: nil,
            messagesAdded: [
                HistoryMessageAdded(
                    message: GmailMessage(
                        id: "fetch-ok",
                        threadId: "thread-fetch-ok",
                        labelIds: ["INBOX"],
                        snippet: "Fetched in background",
                        historyId: "h1",
                        internalDate: nil,
                        payload: nil,
                        sizeEstimate: nil
                    )
                ),
                HistoryMessageAdded(
                    message: GmailMessage(
                        id: "fetch-fail",
                        threadId: "thread-fetch-fail",
                        labelIds: ["INBOX"],
                        snippet: "This one should fail",
                        historyId: "h1",
                        internalDate: nil,
                        payload: nil,
                        sizeEstimate: nil
                    )
                )
            ],
            messagesDeleted: nil,
            labelsAdded: nil,
            labelsRemoved: nil
        )

        let backgroundContext = stack.newBackgroundContext()
        let result = await processor.processHistoryChanges(histories: [history], in: backgroundContext)

        let verificationContext = stack.newBackgroundContext()
        let fetchedMessage = await verificationContext.perform {
            try? verificationContext.fetchMessage(byId: "fetch-ok")
        }
        let missingMessage = await verificationContext.perform {
            try? verificationContext.fetchMessage(byId: "fetch-fail")
        }

        XCTAssertEqual(result, BackgroundMessageProcessingResult(fetchedCount: 1, failedFetchCount: 1))
        XCTAssertEqual(Set(apiClient.getMessageCalledIds), Set(["fetch-ok", "fetch-fail"]))
        XCTAssertEqual(fetchedMessage?.id, "fetch-ok")
        XCTAssertNil(missingMessage)
    }

    func testDeleteMessages_tracksModifiedConversationIDs() async throws {
        await ModificationTracker.shared.reset()

        let stack = TestCoreDataStack()
        let conversation = ConversationBuilder.simple(in: stack.viewContext)
        _ = MessageBuilder()
            .withId("delete-me")
            .withThreadId("thread-delete")
            .inConversation(conversation)
            .build(in: stack.viewContext)
        try stack.saveViewContext()

        let processor = BackgroundMessageProcessor(
            makeBackgroundContext: { stack.newBackgroundContext() },
            saveContext: { stack.saveIfNeeded(context: $0) },
            apiClient: MockGmailAPIClient(),
            syncCoordinator: MockBackgroundSyncCoordinator(seedConversationObjectID: conversation.objectID)
        )

        let backgroundContext = stack.newBackgroundContext()
        let modificationTransaction = await ModificationTracker.shared.beginTransaction()
        await processor.deleteMessages(
            messageIds: ["delete-me"],
            modificationTransaction: modificationTransaction,
            in: backgroundContext
        )

        let modifiedIDs = await ModificationTracker.shared.commitTransaction(modificationTransaction)
        let modifiedURIStrings = Set(modifiedIDs.map { $0.uriRepresentation().absoluteString })

        XCTAssertTrue(
            modifiedURIStrings.contains(conversation.objectID.uriRepresentation().absoluteString)
        )
        await ModificationTracker.shared.consumeCommittedTransaction(modificationTransaction)
    }
}

final class BackgroundSyncErrorHandlerTests: XCTestCase {
    func testHandleError_doesNotRetryRevokedCredentials() {
        let handler = BackgroundSyncErrorHandler()
        let action = handler.handleError(APIError.credentialsRevoked)

        guard case .abortNoRetry = action else {
            return XCTFail("Expected abortNoRetry for revoked credentials, got \(action)")
        }
    }
}

final class LabelOperationProcessorTests: XCTestCase {
    func testProcess_removesAllDuplicateLabelRowsForMatchingId() async throws {
        let stack = TestCoreDataStack()
        let context = stack.viewContext

        let conversation = ConversationBuilder()
            .hasInboxMessages(true)
            .withUnreadCount(1)
            .recentlyActive()
            .build(in: context)
        let message = MessageBuilder()
            .withId("message-1")
            .withThreadId("thread-1")
            .withDate(Date())
            .unread()
            .inConversation(conversation)
            .build(in: context)

        let inboxLabelA = LabelBuilder.inboxLabel(in: context)
        let inboxLabelB = LabelBuilder.inboxLabel(in: context)

        message.addToLabels(inboxLabelA)
        message.addToLabels(inboxLabelB)

        try stack.saveViewContext()

        let modifiedIDs = await LabelOperationProcessor.process(
            items: [
                HistoryLabelRemoved(
                    message: MessageListItem(id: "message-1", threadId: nil),
                    labelIds: ["INBOX"]
                )
            ],
            operation: .remove,
            in: context,
            syncStartTime: nil
        )

        XCTAssertEqual(modifiedIDs, [conversation.objectID])
        XCTAssertFalse(message.labels?.contains(where: { $0.id == "INBOX" }) ?? false)
        XCTAssertFalse(conversation.hasInbox)
        XCTAssertEqual(conversation.inboxUnreadCount, 0)
        XCTAssertNil(conversation.latestInboxDate)
    }

    func testProcess_addTrashLabelDeletesLocalMessage() async throws {
        let stack = TestCoreDataStack()
        let context = stack.viewContext

        let conversation = ConversationBuilder()
            .hasInboxMessages(true)
            .withUnreadCount(0)
            .recentlyActive()
            .build(in: context)
        let message = MessageBuilder()
            .withId("message-trash-1")
            .withThreadId("thread-trash-1")
            .inConversation(conversation)
            .build(in: context)

        _ = LabelBuilder().trash().build(in: context)
        try stack.saveViewContext()

        let modifiedIDs = await LabelOperationProcessor.process(
            items: [
                HistoryLabelAdded(
                    message: MessageListItem(id: "message-trash-1", threadId: nil),
                    labelIds: ["TRASH"]
                )
            ],
            operation: .add,
            in: context,
            syncStartTime: nil
        )

        XCTAssertEqual(modifiedIDs, [conversation.objectID])
        XCTAssertTrue(message.isDeleted)
        try stack.saveViewContext()

        let fetchRequest = Message.fetchRequest()
        fetchRequest.predicate = NSPredicate(format: "id == %@", "message-trash-1")
        fetchRequest.fetchLimit = 1
        let remaining = try context.fetch(fetchRequest).first
        XCTAssertNil(remaining)
    }
}

private final class MockBackgroundSyncCoordinator: @unchecked Sendable, BackgroundSyncMessageCoordinating {
    private let lock = NSLock()
    private let seedConversationObjectID: NSManagedObjectID

    private(set) var prefetchContextIDs: [ObjectIdentifier] = []
    private(set) var savedMessageContextIDs: [ObjectIdentifier] = []
    private(set) var rollupContextIDs: [ObjectIdentifier] = []
    private(set) var rollupConversationIDs: [Set<NSManagedObjectID>] = []

    init(seedConversationObjectID: NSManagedObjectID) {
        self.seedConversationObjectID = seedConversationObjectID
    }

    func prefetchLabelIdsForBackground(in context: NSManagedObjectContext) async -> Set<String> {
        lock.lock()
        prefetchContextIDs.append(ObjectIdentifier(context))
        lock.unlock()
        return ["INBOX"]
    }

    func saveMessage(
        _ gmailMessage: GmailMessage,
        labelIds: Set<String>?,
        modificationTransaction: ModificationTracker.Transaction,
        in context: NSManagedObjectContext
    ) async {
        lock.lock()
        savedMessageContextIDs.append(ObjectIdentifier(context))
        lock.unlock()

        await context.perform {
            guard let conversation = try? context.existingObject(with: self.seedConversationObjectID) as? Conversation else {
                return
            }

            _ = MessageBuilder()
                .withId(gmailMessage.id)
                .withThreadId(gmailMessage.threadId ?? "")
                .withSnippet(gmailMessage.snippet ?? "")
                .inConversation(conversation)
                .build(in: context)
        }
    }

    func updateConversationRollups(
        conversationIDs: Set<NSManagedObjectID>,
        in context: NSManagedObjectContext
    ) async {
        lock.lock()
        rollupContextIDs.append(ObjectIdentifier(context))
        rollupConversationIDs.append(conversationIDs)
        lock.unlock()
    }
}

private final class BackgroundSaveRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private let stack: TestCoreDataStack
    private let failWhenUnsavedMessageIDExists: String

    private(set) var callCount = 0

    init(stack: TestCoreDataStack, failWhenUnsavedMessageIDExists: String) {
        self.stack = stack
        self.failWhenUnsavedMessageIDExists = failWhenUnsavedMessageIDExists
    }

    func save(context: NSManagedObjectContext) -> Bool {
        lock.lock()
        callCount += 1
        lock.unlock()

        var shouldFail = false
        context.performAndWait {
            shouldFail = context.insertedObjects
                .compactMap { $0 as? Message }
                .contains { $0.id == failWhenUnsavedMessageIDExists }
        }

        if shouldFail {
            return false
        }

        return stack.saveIfNeeded(context: context)
    }
}
