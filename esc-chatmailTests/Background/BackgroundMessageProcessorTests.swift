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

    func testBuildChangeSet_skipsSpamMessagesAdded() {
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
                HistoryMessageAdded(message: normalMessage)
            ],
            messagesDeleted: nil,
            labelsAdded: nil,
            labelsRemoved: nil
        )

        let changeSet = BackgroundMessageProcessor.buildChangeSet(from: [record])

        XCTAssertEqual(changeSet.messageIdsToFetch, Set(["m-normal"]))
        XCTAssertFalse(changeSet.messageIdsToFetch.contains("m-spam"))
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
        await processor.processHistoryChanges(histories: [history], in: backgroundContext)

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
        XCTAssertEqual(syncCoordinator.rollupContextIDs, [ObjectIdentifier(backgroundContext)])
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
        await processor.processHistoryChanges(histories: [history], in: backgroundContext)

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
    }
}

private final class MockBackgroundSyncCoordinator: @unchecked Sendable, BackgroundSyncMessageCoordinating {
    private let lock = NSLock()
    private let seedConversationObjectID: NSManagedObjectID

    private(set) var prefetchContextIDs: [ObjectIdentifier] = []
    private(set) var savedMessageContextIDs: [ObjectIdentifier] = []
    private(set) var rollupContextIDs: [ObjectIdentifier] = []

    init(seedConversationObjectID: NSManagedObjectID) {
        self.seedConversationObjectID = seedConversationObjectID
    }

    func prefetchLabelIdsForBackground(in context: NSManagedObjectContext) async -> Set<String> {
        lock.lock()
        prefetchContextIDs.append(ObjectIdentifier(context))
        lock.unlock()
        return ["INBOX"]
    }

    func saveMessage(_ gmailMessage: GmailMessage, labelIds: Set<String>?, in context: NSManagedObjectContext) async {
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

    func updateConversationRollups(in context: NSManagedObjectContext) async {
        lock.lock()
        rollupContextIDs.append(ObjectIdentifier(context))
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
