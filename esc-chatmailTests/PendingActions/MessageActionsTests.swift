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
    private var syncRunCoordinator: SyncRunCoordinator!
    private var context: NSManagedObjectContext!

    override func setUp() {
        super.setUp()
        coreDataStack = TestCoreDataStack()
        pendingActionsManager = MockPendingActionsManager()
        rollupMutationSerializer = ConversationRollupMutationSerializer()
        syncRunCoordinator = SyncRunCoordinator()
        messageActions = MessageActions(
            coreDataStack: coreDataStack,
            pendingActionsManager: pendingActionsManager,
            rollupMutationSerializer: rollupMutationSerializer,
            syncRunCoordinator: syncRunCoordinator
        )
        context = coreDataStack.viewContext
    }

    override func tearDown() {
        context = nil
        messageActions = nil
        rollupMutationSerializer = nil
        syncRunCoordinator = nil
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

    /// Revert-check: fails (deadlocks until the XCTest timeout) if
    /// `MessageActions.performAccountWork` goes back to
    /// `SyncRunCoordinator.acquireRun(kind:for:)`. `acquireRun` parks on the
    /// single-flight boundary, which the held foreground run owns for the whole
    /// test, so `star(message:)` would never return. The non-exclusive
    /// `acquireAccountWorkLease(kind:for:)` grants immediately.
    func testStarCompletesWhileForegroundSyncRunIsActive() async throws {
        let starredLabel = LabelBuilder().starred().build(in: context)
        let message = MessageBuilder()
            .withId("star-during-sync")
            .build(in: context)
        try coreDataStack.saveViewContext()

        guard let blockingRun = await syncRunCoordinator.beginRun(kind: .foregroundIncremental) else {
            return XCTFail("Expected a foreground run to hold the exclusive boundary")
        }

        // Deliberately un-wrapped and un-released: the local mutation must
        // complete while the unrelated sync run still owns the boundary.
        await messageActions.star(message: message)

        XCTAssertTrue(message.labels?.contains(starredLabel) == true)
        XCTAssertNotNil(message.localModifiedAt)

        let queuedActions = await pendingActionsManager.queuedSingleActions
        XCTAssertEqual(queuedActions.map { $0.messageId }, ["star-during-sync"])
        XCTAssertEqual(queuedActions.map { $0.type }, [.star])

        await syncRunCoordinator.endRun(blockingRun)
    }

    /// Revert-check: fails if `acquireAccountWorkLease` drops its `!isQuiescing`
    /// guard (or if `performAccountWork` stops consulting the coordinator at
    /// all). Once account teardown owns the boundary, no optimistic mutation may
    /// touch the store that is about to be replaced.
    func testStarRequestedDuringAccountTransitionDoesNotMutateOrQueue() async throws {
        let starredLabel = LabelBuilder().starred().build(in: context)
        let message = MessageBuilder()
            .withId("stale-star-during-sign-out")
            .build(in: context)
        try coreDataStack.saveViewContext()

        // Nothing holds the boundary, so teardown acquires it immediately.
        await syncRunCoordinator.beginQuiescence()

        await messageActions.star(message: message)

        XCTAssertFalse(message.labels?.contains(starredLabel) == true)
        XCTAssertNil(message.localModifiedAt)
        let queuedActions = await pendingActionsManager.queuedSingleActions
        XCTAssertTrue(queuedActions.isEmpty)

        await syncRunCoordinator.endQuiescence()
    }

    /// Revert-check: fails if `beginQuiescence()` stops draining non-exclusive
    /// leases (i.e. if its `while activeRun != nil || !accountWorkLeases.isEmpty`
    /// loop loses the lease half, or if `endRun` stops calling
    /// `resumeBoundaryDrainWaitersIfDrained()` for a lease). Teardown would then
    /// return while a message action is still mid-mutation.
    func testAccountTransitionWaitsForInFlightMessageActionLease() async throws {
        let conversation = ConversationBuilder()
            .visible()
            .withUnreadCount(0)
            .build(in: context)
        let inboxLabel = LabelBuilder().inbox().build(in: context)
        let message = MessageBuilder()
            .withId("lease-held-during-sign-out")
            .read()
            .inConversation(conversation)
            .build(in: context)
        message.addToLabels(inboxLabel)
        try coreDataStack.saveViewContext()

        let gatingManager = BlockingReadStatePendingActionsManager()
        let actions = MessageActions(
            coreDataStack: coreDataStack,
            pendingActionsManager: gatingManager,
            rollupMutationSerializer: rollupMutationSerializer,
            syncRunCoordinator: syncRunCoordinator
        )

        let actionTask = Task {
            await actions.markAsUnread(message: message)
        }
        // The gate opens inside `queueAction`, which runs while the account-work
        // lease is still held.
        await gatingManager.waitUntilMarkUnreadQueueStarts()

        let transitionCompleted = AccountBoundaryFlag()
        let transitionTask = Task {
            await self.syncRunCoordinator.beginQuiescence()
            transitionCompleted.set()
        }
        await waitUntilAccountTransitionStarts()

        for _ in 0..<20 {
            await Task.yield()
        }
        XCTAssertFalse(
            transitionCompleted.isSet,
            "Account teardown must wait for an outstanding account-work lease"
        )

        await gatingManager.releaseMarkUnreadQueue()
        await actionTask.value
        await transitionTask.value
        XCTAssertTrue(transitionCompleted.isSet)

        await syncRunCoordinator.endQuiescence()
    }

    /// Revert-check: fails if `acquireAccountWorkLease` regains the
    /// `!Task.isCancelled` guard that `acquireRun` has (or if
    /// `performAccountWork` reverts to `acquireRun`, which both checks
    /// cancellation and parks behind the held foreground run). A UI action from
    /// a cancelled SwiftUI task must still apply and enqueue.
    func testArchiveConversationSurvivesCallerCancellationDuringSync() async throws {
        let conversation = ConversationBuilder()
            .visible()
            .build(in: context)
        let inboxLabel = LabelBuilder().inbox().build(in: context)
        let message = MessageBuilder()
            .withId("archive-during-sync")
            .inConversation(conversation)
            .build(in: context)
        message.addToLabels(inboxLabel)
        try coreDataStack.saveViewContext()

        guard let blockingRun = await syncRunCoordinator.beginRun(kind: .foregroundIncremental) else {
            return XCTFail("Expected a foreground run to hold the exclusive boundary")
        }

        let task = Task { @MainActor in
            await self.messageActions.archiveConversation(conversation: conversation)
        }
        task.cancel()
        await task.value

        XCTAssertNotNil(conversation.archivedAt)
        let queuedConversationActions = await pendingActionsManager.queuedConversationActions
        XCTAssertEqual(queuedConversationActions.map { $0.type }, [.archiveConversation])

        await syncRunCoordinator.endRun(blockingRun)
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
            pendingActionsManager: pendingActionsManager,
            syncRunCoordinator: syncRunCoordinator
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

    func testSingleReadStateActionsQueueInSerializedMutationOrder() async throws {
        let conversation = ConversationBuilder()
            .visible()
            .withUnreadCount(0)
            .build(in: context)
        let inboxLabel = LabelBuilder().inbox().build(in: context)
        let message = MessageBuilder()
            .withId("serialized-pending-action-order")
            .read()
            .inConversation(conversation)
            .build(in: context)
        message.addToLabels(inboxLabel)
        try coreDataStack.saveViewContext()

        let orderingManager = BlockingReadStatePendingActionsManager()
        let serializer = ConversationRollupMutationSerializer()
        let actions = MessageActions(
            coreDataStack: coreDataStack,
            pendingActionsManager: orderingManager,
            rollupMutationSerializer: serializer,
            syncRunCoordinator: syncRunCoordinator
        )
        let messageObjectID = message.objectID
        let conversationObjectID = conversation.objectID

        let markUnreadTask = Task {
            await actions.markAsUnread(message: message)
        }
        await orderingManager.waitUntilMarkUnreadQueueStarts()

        let markReadTask = Task {
            await actions.markAsRead(messageID: messageObjectID)
        }
        try? await Task.sleep(nanoseconds: 50_000_000)

        let queuedTypesBeforeRelease = await orderingManager.queuedActionTypes()
        XCTAssertTrue(queuedTypesBeforeRelease.isEmpty)

        await orderingManager.releaseMarkUnreadQueue()
        await markUnreadTask.value
        await markReadTask.value

        let queuedTypes = await orderingManager.queuedActionTypes()
        XCTAssertEqual(queuedTypes, [.markUnread, .markRead])

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

    func testReadMutationWinsOverPreparedStaleSyncMessageSave() async throws {
        let conversation = ConversationBuilder()
            .visible()
            .withUnreadCount(1)
            .build(in: context)
        let inboxLabel = LabelBuilder().inbox().build(in: context)
        let message = MessageBuilder()
            .withId("read-before-stale-sync-save")
            .unread()
            .inConversation(conversation)
            .build(in: context)
        message.addToLabels(inboxLabel)
        try coreDataStack.saveViewContext()
        let messageObjectID = message.objectID

        let staleContext = coreDataStack.newBackgroundContext()
        await staleContext.perform {
            guard let staleMessage = try? staleContext.existingObject(with: messageObjectID) as? Message else {
                return
            }
            staleMessage.isUnread = true
            staleMessage.snippet = "stale sync body"
        }

        await messageActions.markAsRead(message: message)
        await staleContext.perform {
            try? staleContext.save()
        }

        let verificationContext = coreDataStack.newBackgroundContext()
        let durableUnread = await verificationContext.perform {
            (try? verificationContext.existingObject(with: messageObjectID) as? Message)?.isUnread
        }
        XCTAssertEqual(durableUnread, false)
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
            },
            syncRunCoordinator: syncRunCoordinator
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

    private func waitUntilAccountTransitionStarts(
        timeout: TimeInterval = 2.0,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let deadline = Date().addingTimeInterval(timeout)

        while Date() < deadline {
            if await syncRunCoordinator.makeAccountWorkRequest() == nil {
                return
            }
            await Task.yield()
        }

        XCTFail("Timed out waiting for account transition", file: file, line: line)
    }
}

/// Minimal cross-task boolean so a test can assert that account teardown has
/// *not* completed yet without introducing a data race on a captured `var`.
private final class AccountBoundaryFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var isSet: Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func set() {
        lock.lock()
        value = true
        lock.unlock()
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

private actor BlockingReadStatePendingActionsManager: PendingActionsManagerProtocol {
    private let markUnreadQueueStarted = RollupTestGate()
    private let allowMarkUnreadQueue = RollupTestGate()
    private var actionTypes: [PendingAction.ActionType] = []

    func waitUntilMarkUnreadQueueStarts() async {
        await markUnreadQueueStarted.wait()
    }

    func releaseMarkUnreadQueue() async {
        await allowMarkUnreadQueue.open()
    }

    func queuedActionTypes() -> [PendingAction.ActionType] {
        actionTypes
    }

    func queueAction(
        type: PendingAction.ActionType,
        messageId: String,
        payload: [String: Any]?
    ) async {
        if type == .markUnread {
            await markUnreadQueueStarted.open()
            await allowMarkUnreadQueue.wait()
        }
        actionTypes.append(type)
    }

    func queueConversationAction(
        type: PendingAction.ActionType,
        sourceConversationId: UUID,
        messageIds: [String]
    ) async {
        actionTypes.append(type)
    }

    func processAllPendingActions() async {}
    func pendingActionCount() async -> Int { actionTypes.count }
    func hasPendingAction(forMessageId messageId: String, type: PendingAction.ActionType) async -> Bool {
        actionTypes.contains(type)
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
