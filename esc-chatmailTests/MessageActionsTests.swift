import XCTest
import CoreData
@testable import esc_chatmail

extension TestCoreDataStack: MessageActionsCoreDataStacking {}

@MainActor
final class MessageActionsTests: XCTestCase {
    private var coreDataStack: TestCoreDataStack!
    private var pendingActionsManager: MockPendingActionsManager!
    private var messageActions: MessageActions!
    private var context: NSManagedObjectContext!

    override func setUp() {
        super.setUp()
        coreDataStack = TestCoreDataStack()
        pendingActionsManager = MockPendingActionsManager()
        messageActions = MessageActions(
            coreDataStack: coreDataStack,
            pendingActionsManager: pendingActionsManager
        )
        context = coreDataStack.viewContext
    }

    override func tearDown() {
        context = nil
        messageActions = nil
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
        try coreDataStack.saveViewContext()

        let messageIDs = messageActions.snapshotUnreadConversationMessageObjectIDs(
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
                conversation.inboxUnreadCount == 0
        }

        let queuedActions = await pendingActionsManager.queuedSingleActions
        XCTAssertEqual(queuedActions.map(\.messageId), ["message-to-read"])
        XCTAssertEqual(queuedActions.map(\.type), [.markRead])
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

        let messageIDsAtOpen = messageActions.snapshotUnreadConversationMessageObjectIDs(
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

        let queuedActions = await pendingActionsManager.queuedSingleActions
        XCTAssertEqual(queuedActions.map(\.messageId), ["message-visible-at-open"])
        XCTAssertEqual(queuedActions.map(\.type), [.markRead])
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

actor MockPendingActionsManager: PendingActionsManagerProtocol {
    private(set) var queuedSingleActions: [(type: PendingAction.ActionType, messageId: String)] = []

    func queueAction(type: PendingAction.ActionType, messageId: String, payload: [String : Any]?) async {
        queuedSingleActions.append((type: type, messageId: messageId))
    }

    func queueConversationAction(type: PendingAction.ActionType, sourceConversationId: UUID, messageIds: [String]) async {}
    func processAllPendingActions() async {}
    func pendingActionCount() async -> Int { queuedSingleActions.count }
    func hasPendingAction(forMessageId messageId: String, type: PendingAction.ActionType) async -> Bool {
        queuedSingleActions.contains { $0.messageId == messageId && $0.type == type }
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
