import XCTest
import CoreData
@testable import esc_chatmail

extension TestCoreDataStack: MessageActionsCoreDataStacking {}

@MainActor
final class MessageActionsTests: XCTestCase {
    private var coreDataStack: TestCoreDataStack!
    private var pendingActionsManager: MockPendingActionsManager!
    private var messageActions: MessageActions!
    private var rollupMutationSerializer: ConversationRollupMutationSerializer!
    private var context: NSManagedObjectContext!

    override func setUp() {
        super.setUp()
        coreDataStack = TestCoreDataStack()
        pendingActionsManager = MockPendingActionsManager()
        rollupMutationSerializer = ConversationRollupMutationSerializer()
        messageActions = MessageActions(
            coreDataStack: coreDataStack,
            pendingActionsManager: pendingActionsManager,
            rollupMutationSerializer: rollupMutationSerializer
        )
        context = coreDataStack.viewContext
    }

    override func tearDown() {
        context = nil
        messageActions = nil
        rollupMutationSerializer = nil
        pendingActionsManager = nil
        coreDataStack = nil
        super.tearDown()
    }

    func testStar_addsStarredLabelMarksLocalModificationAndQueuesPendingAction() async throws {
        let starredLabel = LabelBuilder().starred().build(in: context)
        let message = MessageBuilder()
            .withId("message-to-star")
            .build(in: context)
        try coreDataStack.saveViewContext()

        await messageActions.star(message: message)

        XCTAssertTrue(message.labels?.contains(starredLabel) == true)
        XCTAssertNotNil(message.localModifiedAt)

        let queuedActions = await pendingActionsManager.queuedSingleActions
        XCTAssertEqual(queuedActions.count, 1)
        XCTAssertEqual(queuedActions.first?.type, .star)
        XCTAssertEqual(queuedActions.first?.messageId, "message-to-star")
    }

    func testUnstar_removesStarredLabelMarksLocalModificationAndQueuesPendingAction() async throws {
        let starredLabel = LabelBuilder().starred().build(in: context)
        let message = MessageBuilder()
            .withId("message-to-unstar")
            .build(in: context)
        message.addToLabels(starredLabel)
        try coreDataStack.saveViewContext()

        await messageActions.unstar(message: message)

        XCTAssertFalse(message.labels?.contains(starredLabel) == true)
        XCTAssertNotNil(message.localModifiedAt)

        let queuedActions = await pendingActionsManager.queuedSingleActions
        XCTAssertEqual(queuedActions.count, 1)
        XCTAssertEqual(queuedActions.first?.type, .unstar)
        XCTAssertEqual(queuedActions.first?.messageId, "message-to-unstar")
    }

    func testStar_doesNothingWhenMessageAlreadyStarred() async throws {
        let starredLabel = LabelBuilder().starred().build(in: context)
        let message = MessageBuilder()
            .withId("already-starred")
            .build(in: context)
        message.addToLabels(starredLabel)
        try coreDataStack.saveViewContext()

        await messageActions.star(message: message)

        let queuedActions = await pendingActionsManager.queuedSingleActions
        XCTAssertTrue(queuedActions.isEmpty)
    }

    func testStar_doesNotQueuePendingActionWhenLocalSaveFails() async throws {
        _ = LabelBuilder().starred().build(in: context)
        let message = MessageBuilder()
            .withId("message-save-fails")
            .build(in: context)
        try coreDataStack.saveViewContext()

        let failingStack = FailingSaveCoreDataStack(wrapping: coreDataStack)
        let actions = MessageActions(
            coreDataStack: failingStack,
            pendingActionsManager: pendingActionsManager
        )

        await actions.star(message: message)

        // The optimistic in-memory change may still apply, but a remote sync must
        // not be queued when we couldn't persist the change locally.
        let queuedActions = await pendingActionsManager.queuedSingleActions
        XCTAssertTrue(queuedActions.isEmpty, "Remote star must not be queued when the local save fails")
    }

    func testMarkMessagesAsReadBatch_marksSnapshotUnreadMessagesOffMainThread() async throws {
        let conversation = ConversationBuilder()
            .visible()
            .withUnreadCount(2)
            .build(in: context)
        let inboxLabel = LabelBuilder().inbox().build(in: context)
        let includedMessage = MessageBuilder()
            .withId("message-to-read")
            .unread()
            .inConversation(conversation)
            .build(in: context)
        includedMessage.addToLabels(inboxLabel)
        let excludedMessage = MessageBuilder()
            .withId("draft-message")
            .unread()
            .inConversation(conversation)
            .build(in: context)
        let draftLabel = LabelBuilder().draft().build(in: context)
        excludedMessage.addToLabels(draftLabel)

        let nonInboxMessage = MessageBuilder()
            .withId("sent-message")
            .unread()
            .inConversation(conversation)
            .build(in: context)
        try coreDataStack.saveViewContext()
        let messageIDs = messageActions.snapshotUnreadInboxMessageObjectIDs(
            conversationID: conversation.id
        )

        await messageActions.markMessagesAsReadBatch(
            messageIDs: messageIDs,
            conversationID: conversation.objectID
        )

        await waitUntil {
            self.context.refreshAllObjects()
            return !includedMessage.isUnread &&
                excludedMessage.isUnread &&
                nonInboxMessage.isUnread &&
                conversation.inboxUnreadCount == 0
        }

        let queuedSingleActions = await pendingActionsManager.queuedSingleActions
        XCTAssertTrue(queuedSingleActions.isEmpty)

        let queuedConversationActions = await pendingActionsManager.queuedConversationActions
        XCTAssertEqual(queuedConversationActions.count, 1)
        XCTAssertEqual(queuedConversationActions.first?.type, .markRead)
        XCTAssertEqual(queuedConversationActions.first?.sourceConversationId, conversation.id)
        XCTAssertEqual(queuedConversationActions.first?.messageIds, ["message-to-read"])
    }

    func testMarkAsReadMessageRecomputesRollupInSerializedBackgroundContext() async throws {
        let conversation = ConversationBuilder()
            .visible()
            .withUnreadCount(1)
            .build(in: context)
        let inboxLabel = LabelBuilder().inbox().build(in: context)
        let message = MessageBuilder()
            .withId("serialized-single-read")
            .unread()
            .inConversation(conversation)
            .build(in: context)
        message.addToLabels(inboxLabel)
        try coreDataStack.saveViewContext()

        await messageActions.markAsRead(message: message)

        await waitUntil {
            self.context.refreshAllObjects()
            return !message.isUnread && conversation.inboxUnreadCount == 0
        }

        let queuedActions = await pendingActionsManager.queuedSingleActions
        XCTAssertEqual(queuedActions.map(\.type), [.markRead])
        XCTAssertEqual(queuedActions.first?.messageId, message.id)
    }

    func testMarkAsReadMessageIDRecomputesRollupInSerializedBackgroundContext() async throws {
        let conversation = ConversationBuilder()
            .visible()
            .withUnreadCount(1)
            .build(in: context)
        let inboxLabel = LabelBuilder().inbox().build(in: context)
        let message = MessageBuilder()
            .withId("serialized-object-id-read")
            .unread()
            .inConversation(conversation)
            .build(in: context)
        message.addToLabels(inboxLabel)
        try coreDataStack.saveViewContext()

        await messageActions.markAsRead(messageID: message.objectID)

        await waitUntil {
            self.context.refreshAllObjects()
            return !message.isUnread && conversation.inboxUnreadCount == 0
        }

        let queuedActions = await pendingActionsManager.queuedSingleActions
        XCTAssertEqual(queuedActions.map(\.type), [.markRead])
        XCTAssertEqual(queuedActions.first?.messageId, message.id)
    }

    func testMarkMessagesAsReadBatchRevalidatesInboxAndConversation() async throws {
        let sourceConversation = ConversationBuilder().visible().build(in: context)
        let otherConversation = ConversationBuilder().visible().build(in: context)
        let inboxLabel = LabelBuilder().inbox().build(in: context)
        let message = MessageBuilder()
            .withId("revalidate-read-target")
            .unread()
            .inConversation(sourceConversation)
            .build(in: context)
        message.addToLabels(inboxLabel)
        try coreDataStack.saveViewContext()

        await messageActions.markMessagesAsReadBatch(
            messageIDs: [message.objectID],
            conversationID: otherConversation.objectID
        )

        context.refreshAllObjects()
        XCTAssertTrue(message.isUnread)
        let queuedConversationActions = await pendingActionsManager.queuedConversationActions
        XCTAssertTrue(queuedConversationActions.isEmpty)
    }

    func testMarkMessagesAsReadBatch_keepsLaterUnreadInboxMessageUnreadAndCounted() async throws {
        let conversation = ConversationBuilder()
            .visible()
            .withUnreadCount(1)
            .build(in: context)
        let inboxLabel = LabelBuilder().inbox().build(in: context)
        let initialMessage = MessageBuilder()
            .withId("message-visible-at-open")
            .unread()
            .inConversation(conversation)
            .build(in: context)
        initialMessage.addToLabels(inboxLabel)
        try coreDataStack.saveViewContext()

        let messageIDsAtOpen = messageActions.snapshotUnreadInboxMessageObjectIDs(
            conversationID: conversation.id
        )

        let laterMessage = MessageBuilder()
            .withId("message-arrived-later")
            .unread()
            .inConversation(conversation)
            .build(in: context)
        laterMessage.addToLabels(inboxLabel)
        conversation.inboxUnreadCount = 2
        try coreDataStack.saveViewContext()

        await messageActions.markMessagesAsReadBatch(
            messageIDs: messageIDsAtOpen,
            conversationID: conversation.objectID
        )

        await waitUntil {
            self.context.refreshAllObjects()
            return !initialMessage.isUnread &&
                laterMessage.isUnread &&
                conversation.inboxUnreadCount == 1
        }

        let queuedSingleActions = await pendingActionsManager.queuedSingleActions
        XCTAssertTrue(queuedSingleActions.isEmpty)

        let queuedConversationActions = await pendingActionsManager.queuedConversationActions
        XCTAssertEqual(queuedConversationActions.count, 1)
        XCTAssertEqual(queuedConversationActions.first?.type, .markRead)
        XCTAssertEqual(queuedConversationActions.first?.sourceConversationId, conversation.id)
        XCTAssertEqual(queuedConversationActions.first?.messageIds, ["message-visible-at-open"])
    }

    func testConcurrentReadBatchesSerializeRollupRecomputation() async throws {
        let conversation = ConversationBuilder()
            .visible()
            .withUnreadCount(2)
            .build(in: context)
        let inboxLabel = LabelBuilder().inbox().build(in: context)
        let firstMessage = MessageBuilder()
            .withId("first-concurrent-read")
            .unread()
            .inConversation(conversation)
            .build(in: context)
        firstMessage.addToLabels(inboxLabel)
        let secondMessage = MessageBuilder()
            .withId("second-concurrent-read")
            .unread()
            .inConversation(conversation)
            .build(in: context)
        secondMessage.addToLabels(inboxLabel)
        try coreDataStack.saveViewContext()

        let conversationObjectID = conversation.objectID
        let firstMessageObjectID = firstMessage.objectID
        let secondMessageObjectID = secondMessage.objectID
        let firstTask = Task {
            await messageActions.markMessagesAsReadBatch(
                messageIDs: [firstMessageObjectID],
                conversationID: conversationObjectID
            )
        }
        let secondTask = Task {
            await messageActions.markMessagesAsReadBatch(
                messageIDs: [secondMessageObjectID],
                conversationID: conversationObjectID
            )
        }
        await firstTask.value
        await secondTask.value

        context.refreshAllObjects()
        XCTAssertFalse(firstMessage.isUnread)
        XCTAssertFalse(secondMessage.isUnread)
        XCTAssertEqual(conversation.inboxUnreadCount, 0)
        let queuedActions = await pendingActionsManager.queuedConversationActions
        XCTAssertEqual(queuedActions.count, 2)
    }

    func testReadBatchWaitsForInFlightSyncRollupAndWinsFinalCount() async throws {
        let conversation = ConversationBuilder()
            .visible()
            .withUnreadCount(1)
            .build(in: context)
        let inboxLabel = LabelBuilder().inbox().build(in: context)
        let message = MessageBuilder()
            .withId("read-during-sync-rollup")
            .unread()
            .inConversation(conversation)
            .build(in: context)
        message.addToLabels(inboxLabel)
        try coreDataStack.saveViewContext()

        let conversationObjectID = conversation.objectID
        let messageObjectID = message.objectID
        let conversationKey = conversationObjectID.uriRepresentation().absoluteString
        let syncContext = coreDataStack.newBackgroundContext()
        await syncContext.perform {
            let staleConversation = try? syncContext.existingObject(
                with: conversationObjectID
            ) as? Conversation
            let staleMessage = try? syncContext.existingObject(with: messageObjectID) as? Message
            _ = staleConversation?.inboxUnreadCount
            _ = staleMessage?.isUnread
        }

        let syncStarted = RollupTestGate()
        let syncCanSave = RollupTestGate()
        let syncTask = Task {
            await rollupMutationSerializer.perform(conversationKeys: [conversationKey]) {
                await syncContext.perform {
                    syncContext.refreshAllObjects()
                    _ = (try? syncContext.existingObject(with: messageObjectID) as? Message)?.isUnread
                }
                await syncStarted.open()
                await syncCanSave.wait()
                await syncContext.perform {
                    guard let staleConversation = try? syncContext.existingObject(
                        with: conversationObjectID
                    ) as? Conversation,
                          let staleMessage = try? syncContext.existingObject(
                            with: messageObjectID
                          ) as? Message else {
                        return
                    }
                    staleConversation.inboxUnreadCount = staleMessage.isUnread ? 1 : 0
                    try? syncContext.save()
                }
            }
        }

        await syncStarted.wait()
        let readTask = Task {
            await messageActions.markMessagesAsReadBatch(
                messageIDs: [messageObjectID],
                conversationID: conversationObjectID
            )
        }

        try? await Task.sleep(nanoseconds: 50_000_000)
        let pendingCountBeforeSyncSave = await pendingActionsManager.pendingActionCount()
        XCTAssertEqual(pendingCountBeforeSyncSave, 0)

        await syncCanSave.open()
        await syncTask.value
        await readTask.value

        let verificationContext = coreDataStack.newBackgroundContext()
        let durableState = await verificationContext.perform {
            let durableConversation = try? verificationContext.existingObject(
                with: conversationObjectID
            ) as? Conversation
            let durableMessage = try? verificationContext.existingObject(
                with: messageObjectID
            ) as? Message
            return (durableMessage?.isUnread, durableConversation?.inboxUnreadCount)
        }
        XCTAssertEqual(durableState.0, false)
        XCTAssertEqual(durableState.1, 0)
    }

    func testMarkConversationAsRead_usesBatchUpdateAndSinglePendingAction() async throws {
        let conversation = ConversationBuilder()
            .visible()
            .withUnreadCount(2)
            .build(in: context)
        let inboxLabel = LabelBuilder().inbox().build(in: context)
        let firstMessage = MessageBuilder()
            .withId("inbox-unread-1")
            .unread()
            .inConversation(conversation)
            .build(in: context)
        firstMessage.addToLabels(inboxLabel)
        let secondMessage = MessageBuilder()
            .withId("inbox-unread-2")
            .unread()
            .inConversation(conversation)
            .build(in: context)
        secondMessage.addToLabels(inboxLabel)
        let nonInboxMessage = MessageBuilder()
            .withId("sent-unread")
            .unread()
            .inConversation(conversation)
            .build(in: context)
        try coreDataStack.saveViewContext()

        await messageActions.markConversationAsRead(conversation: conversation)

        await waitUntil {
            self.context.refreshAllObjects()
            return !firstMessage.isUnread &&
                !secondMessage.isUnread &&
                nonInboxMessage.isUnread &&
                conversation.inboxUnreadCount == 0
        }

        let queuedSingleActions = await pendingActionsManager.queuedSingleActions
        XCTAssertTrue(queuedSingleActions.isEmpty)

        let queuedConversationActions = await pendingActionsManager.queuedConversationActions
        XCTAssertEqual(queuedConversationActions.count, 1)
        XCTAssertEqual(queuedConversationActions.first?.type, .markRead)
        XCTAssertEqual(queuedConversationActions.first?.sourceConversationId, conversation.id)
        XCTAssertEqual(
            Set(queuedConversationActions.first?.messageIds ?? []),
            Set(["inbox-unread-1", "inbox-unread-2"])
        )
    }

    func testMarkConversationAsUnread_doesNotFallBackToNonInboxMessage() async throws {
        let conversation = ConversationBuilder()
            .visible()
            .withUnreadCount(0)
            .build(in: context)
        let nonInboxMessage = MessageBuilder()
            .withId("sent-message")
            .read()
            .inConversation(conversation)
            .build(in: context)
        try coreDataStack.saveViewContext()

        await messageActions.markConversationAsUnread(conversation: conversation)

        XCTAssertFalse(nonInboxMessage.isUnread)
        XCTAssertEqual(conversation.inboxUnreadCount, 0)
        let queuedActions = await pendingActionsManager.queuedSingleActions
        XCTAssertTrue(queuedActions.isEmpty)
    }

    func testExactUnreadInboxSnapshotDoesNotIncludeUnrelatedOrNonInboxMessages() throws {
        let conversation = ConversationBuilder()
            .visible()
            .withUnreadCount(2)
            .build(in: context)
        let inboxLabel = LabelBuilder().inbox().build(in: context)
        let eligibleArrival = MessageBuilder()
            .withId("eligible-arrival")
            .unread()
            .inConversation(conversation)
            .build(in: context)
        eligibleArrival.addToLabels(inboxLabel)
        let unrelatedUnread = MessageBuilder()
            .withId("preserved-unread")
            .unread()
            .inConversation(conversation)
            .build(in: context)
        unrelatedUnread.addToLabels(inboxLabel)
        let nonInboxArrival = MessageBuilder()
            .withId("non-inbox-arrival")
            .unread()
            .inConversation(conversation)
            .build(in: context)
        let readInboxArrival = MessageBuilder()
            .withId("read-inbox-arrival")
            .read()
            .inConversation(conversation)
            .build(in: context)
        readInboxArrival.addToLabels(inboxLabel)
        try coreDataStack.saveViewContext()

        let snapshot = messageActions.snapshotUnreadInboxMessageObjectIDs(
            messageObjectIDs: [
                eligibleArrival.objectID,
                nonInboxArrival.objectID,
                readInboxArrival.objectID
            ]
        )

        XCTAssertEqual(snapshot, [eligibleArrival.objectID])
        XCTAssertTrue(unrelatedUnread.isUnread)
    }

    func testMarkMessagesAsReadBatch_rollsBackWhenUnreadInboxCountFails() async throws {
        let conversation = ConversationBuilder()
            .visible()
            .withUnreadCount(1)
            .build(in: context)
        let inboxLabel = LabelBuilder().inbox().build(in: context)
        let message = MessageBuilder()
            .withId("message-to-keep-unread")
            .unread()
            .inConversation(conversation)
            .build(in: context)
        message.addToLabels(inboxLabel)
        try coreDataStack.saveViewContext()

        let failingActions = MessageActions(
            coreDataStack: coreDataStack,
            pendingActionsManager: pendingActionsManager,
            unreadInboxMessageCounter: { _, _ in
                throw MessageActionsTestError.unreadCountFailed
            }
        )
        let messageIDs = failingActions.snapshotUnreadInboxMessageObjectIDs(
            conversationID: conversation.id
        )

        await failingActions.markMessagesAsReadBatch(
            messageIDs: messageIDs,
            conversationID: conversation.objectID
        )

        context.refreshAllObjects()
        XCTAssertTrue(message.isUnread)
        XCTAssertEqual(conversation.inboxUnreadCount, 1)
        let queuedActions = await pendingActionsManager.queuedConversationActions
        XCTAssertTrue(queuedActions.isEmpty)
    }

    private func waitUntil(
        timeout: TimeInterval = 2.0,
        pollIntervalNanoseconds: UInt64 = 20_000_000,
        file: StaticString = #filePath,
        line: UInt = #line,
        condition: @escaping @MainActor () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)

        while Date() < deadline {
            if condition() {
                return
            }
            try? await Task.sleep(nanoseconds: pollIntervalNanoseconds)
        }

        XCTFail("Timed out waiting for condition", file: file, line: line)
    }
}

private actor RollupTestGate {
    private var isOpen = false
    private var continuations: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { continuation in
            continuations.append(continuation)
        }
    }

    func open() {
        guard !isOpen else { return }
        isOpen = true
        let pendingContinuations = continuations
        continuations.removeAll()
        pendingContinuations.forEach { $0.resume() }
    }
}

private enum MessageActionsTestError: Error {
    case unreadCountFailed
}

/// Wraps a real test stack but reports every `saveIfNeeded` as failed, to exercise the
/// "don't sync remotely when the local save failed" gating in `MessageActions`.
private final class FailingSaveCoreDataStack: MessageActionsCoreDataStacking {
    private let wrapped: TestCoreDataStack

    init(wrapping wrapped: TestCoreDataStack) {
        self.wrapped = wrapped
    }

    var viewContext: NSManagedObjectContext { wrapped.viewContext }

    func newBackgroundContext() -> NSManagedObjectContext {
        wrapped.newBackgroundContext()
    }

    func saveIfNeeded(context: NSManagedObjectContext, caller: String) -> Bool {
        false
    }
}

actor MockPendingActionsManager: PendingActionsManagerProtocol {
    private(set) var queuedSingleActions: [(type: PendingAction.ActionType, messageId: String)] = []
    private(set) var queuedConversationActions: [(type: PendingAction.ActionType, sourceConversationId: UUID, messageIds: [String])] = []

    func queueAction(type: PendingAction.ActionType, messageId: String, payload: [String : Any]?) async {
        queuedSingleActions.append((type: type, messageId: messageId))
    }

    func queueConversationAction(type: PendingAction.ActionType, sourceConversationId: UUID, messageIds: [String]) async {
        queuedConversationActions.append((
            type: type,
            sourceConversationId: sourceConversationId,
            messageIds: messageIds
        ))
    }

    func processAllPendingActions() async {}
    func pendingActionCount() async -> Int {
        queuedSingleActions.count + queuedConversationActions.count
    }

    func hasPendingAction(forMessageId messageId: String, type: PendingAction.ActionType) async -> Bool {
        queuedSingleActions.contains { $0.messageId == messageId && $0.type == type } ||
            queuedConversationActions.contains { action in
                action.type == type && action.messageIds.contains(messageId)
            }
    }
    func cancelPendingAction(forMessageId messageId: String, type: PendingAction.ActionType) async {}
    func stopMonitoring() {}
    func abandonedActionCount() async -> Int { 0 }
    func fetchAbandonedActions() async -> [AbandonedActionInfo] { [] }
    func retryAbandonedAction(objectID: NSManagedObjectID) async {}
    func retryAllAbandonedActions() async {}
    func dismissAbandonedAction(objectID: NSManagedObjectID) async {}
    func dismissAllAbandonedActions() async {}
}
