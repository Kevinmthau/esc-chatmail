import XCTest
import CoreData
@testable import esc_chatmail

/// Every fixture, save, and assertion goes through the suite's `viewContext`,
/// the main-queue context of `MainQueueMessageActionsCoreDataStack`, never
/// `coreDataStack.viewContext`, which is private-queue. `MessageActions` is
/// `@MainActor` and fetches, mutates, and saves its stack's view context
/// directly, which is on-queue only for a main-queue context. See
/// `TestCoreDataStack.makeMainQueueViewContext()` for what the private-queue
/// shape races. Background contexts (`newBackgroundContext()`) stay
/// private-queue and are only touched inside `perform`.
///
/// HONEST SCOPE: no test here can reproduce that race on demand. With
/// `-com.apple.CoreData.ConcurrencyDebug 1` the old shape traps and this shape
/// runs clean.
@MainActor
final class MessageActionsTests: XCTestCase {
    private var coreDataStack: TestCoreDataStack!
    private var messageActionsStack: MainQueueMessageActionsCoreDataStack!
    private var pendingActionsManager: MockPendingActionsManager!
    private var messageActions: MessageActions!
    private var rollupMutationSerializer: ConversationRollupMutationSerializer!
    private var syncRunCoordinator: SyncRunCoordinator!
    private var viewContext: NSManagedObjectContext!

    override func setUp() {
        super.setUp()
        coreDataStack = TestCoreDataStack()
        messageActionsStack = MainQueueMessageActionsCoreDataStack(wrapping: coreDataStack)
        viewContext = messageActionsStack.viewContext
        pendingActionsManager = MockPendingActionsManager()
        rollupMutationSerializer = ConversationRollupMutationSerializer()
        syncRunCoordinator = SyncRunCoordinator()
        messageActions = MessageActions(
            coreDataStack: messageActionsStack,
            pendingActionsManager: pendingActionsManager,
            rollupMutationSerializer: rollupMutationSerializer,
            syncRunCoordinator: syncRunCoordinator
        )
    }

    override func tearDown() {
        viewContext = nil
        messageActions = nil
        rollupMutationSerializer = nil
        syncRunCoordinator = nil
        pendingActionsManager = nil
        messageActionsStack = nil
        coreDataStack = nil
        super.tearDown()
    }

    func testStar_addsStarredLabelMarksLocalModificationAndQueuesPendingAction() async throws {
        let starredLabel = LabelBuilder().starred().build(in: viewContext)
        let message = MessageBuilder()
            .withId("message-to-star")
            .build(in: viewContext)
        try saveViewContext()

        await messageActions.star(message: message)
        viewContext.refreshAllObjects()

        XCTAssertTrue(message.labels?.contains(starredLabel) == true)
        XCTAssertNotNil(message.localModifiedAt)

        let queuedActions = await pendingActionsManager.queuedSingleActions
        XCTAssertEqual(queuedActions.count, 1)
        XCTAssertEqual(queuedActions.first?.type, .star)
        XCTAssertEqual(queuedActions.first?.messageId, "message-to-star")
    }

    func testUnstar_removesStarredLabelMarksLocalModificationAndQueuesPendingAction() async throws {
        let starredLabel = LabelBuilder().starred().build(in: viewContext)
        let message = MessageBuilder()
            .withId("message-to-unstar")
            .build(in: viewContext)
        message.addToLabels(starredLabel)
        try saveViewContext()

        await messageActions.unstar(message: message)
        viewContext.refreshAllObjects()

        XCTAssertFalse(message.labels?.contains(starredLabel) == true)
        XCTAssertNotNil(message.localModifiedAt)

        let queuedActions = await pendingActionsManager.queuedSingleActions
        XCTAssertEqual(queuedActions.count, 1)
        XCTAssertEqual(queuedActions.first?.type, .unstar)
        XCTAssertEqual(queuedActions.first?.messageId, "message-to-unstar")
    }

    func testStar_doesNothingWhenMessageAlreadyStarred() async throws {
        let starredLabel = LabelBuilder().starred().build(in: viewContext)
        let message = MessageBuilder()
            .withId("already-starred")
            .build(in: viewContext)
        message.addToLabels(starredLabel)
        try saveViewContext()

        await messageActions.star(message: message)
        viewContext.refreshAllObjects()

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
        let starredLabel = LabelBuilder().starred().build(in: viewContext)
        let message = MessageBuilder()
            .withId("star-during-sync")
            .build(in: viewContext)
        try saveViewContext()

        guard let blockingRun = await syncRunCoordinator.beginRun(kind: .foregroundIncremental) else {
            return XCTFail("Expected a foreground run to hold the exclusive boundary")
        }

        // Deliberately un-wrapped and un-released: the local mutation must
        // complete while the unrelated sync run still owns the boundary.
        await messageActions.star(message: message)
        viewContext.refreshAllObjects()

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
        let starredLabel = LabelBuilder().starred().build(in: viewContext)
        let message = MessageBuilder()
            .withId("stale-star-during-sign-out")
            .build(in: viewContext)
        try saveViewContext()

        // Nothing holds the boundary, so teardown acquires it immediately.
        await syncRunCoordinator.beginQuiescence()

        await messageActions.star(message: message)
        viewContext.refreshAllObjects()

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
            .build(in: viewContext)
        let inboxLabel = LabelBuilder().inbox().build(in: viewContext)
        let message = MessageBuilder()
            .withId("lease-held-during-sign-out")
            .read()
            .inConversation(conversation)
            .build(in: viewContext)
        message.addToLabels(inboxLabel)
        try saveViewContext()

        let gatingManager = BlockingReadStatePendingActionsManager()
        let actions = MessageActions(
            coreDataStack: messageActionsStack,
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
            .build(in: viewContext)
        let inboxLabel = LabelBuilder().inbox().build(in: viewContext)
        let message = MessageBuilder()
            .withId("archive-during-sync")
            .inConversation(conversation)
            .build(in: viewContext)
        message.addToLabels(inboxLabel)
        try saveViewContext()

        guard let blockingRun = await syncRunCoordinator.beginRun(kind: .foregroundIncremental) else {
            return XCTFail("Expected a foreground run to hold the exclusive boundary")
        }

        let task = Task { @MainActor in
            await self.messageActions.archiveConversation(conversation: conversation)
        }
        task.cancel()
        await task.value
        viewContext.refreshAllObjects()

        XCTAssertNotNil(conversation.archivedAt)
        let queuedConversationActions = await pendingActionsManager.queuedConversationActions
        XCTAssertEqual(queuedConversationActions.map { $0.type }, [.archiveConversation])

        await syncRunCoordinator.endRun(blockingRun)
    }

    /// The user's own reply keeps its optimistic send's local UUID until sync
    /// replaces it with Gmail's echo. In the conversation's single
    /// `batchModify` that ID made Gmail reject the whole request, so the
    /// archive never reached Gmail for the conversation's other messages.
    /// Archive tapped during a reply send now runs right after the optimistic
    /// row exists (`ChatConversationExitActionPolicy`).
    ///
    /// Revert-check: appending every non-empty `message.id` again in the
    /// archive branch of `MessageActions.applyConversationWideMutation`
    /// (instead of `gmailMessageIDForConversationAction`) queues the
    /// optimistic ID and fails this test.
    func testArchiveConversation_withUnechoedOwnReply_queuesOnlyGmailMessageIDs() async throws {
        let fixture = try makeConversationWithUnechoedOwnReply(
            gmailMessageID: "gmail-archive-inbox",
            inboxLabel: LabelBuilder().inbox().build(in: viewContext)
        )

        await messageActions.archiveConversation(conversation: fixture.conversation)
        viewContext.refreshAllObjects()

        let queued = await pendingActionsManager.queuedConversationActions
        XCTAssertEqual(queued.map { $0.type }, [.archiveConversation])
        XCTAssertEqual(queued.first?.messageIds, ["gmail-archive-inbox"])
        // The local change still covers the reply's row.
        XCTAssertNotNil(fixture.optimisticReply.localModifiedAt)
        XCTAssertNotNil(fixture.conversation.archivedAt)
    }

    /// Revert-check: appending every non-empty `message.id` again in
    /// the Report Spam branch of
    /// `MessageActions.applyConversationWideMutation` queues the optimistic
    /// ID and fails this test.
    func testReportSpamConversation_withUnechoedOwnReply_queuesOnlyGmailMessageIDs() async throws {
        let fixture = try makeConversationWithUnechoedOwnReply(
            gmailMessageID: "gmail-spam-inbox",
            inboxLabel: LabelBuilder().inbox().build(in: viewContext)
        )

        await messageActions.reportSpamConversation(conversation: fixture.conversation)
        viewContext.refreshAllObjects()

        let queued = await pendingActionsManager.queuedConversationActions
        XCTAssertEqual(queued.map { $0.type }, [.reportSpam])
        XCTAssertEqual(queued.first?.messageIds, ["gmail-spam-inbox"])
        XCTAssertNotNil(fixture.optimisticReply.localModifiedAt)
    }

    /// The list's batch Archive and Report Spam share the same helpers.
    func testBatchArchiveAndReportSpam_withUnechoedOwnReply_queueOnlyGmailMessageIDs() async throws {
        let inboxLabel = LabelBuilder().inbox().build(in: viewContext)
        let archived = try makeConversationWithUnechoedOwnReply(
            gmailMessageID: "gmail-batch-archive",
            inboxLabel: inboxLabel
        )
        let reported = try makeConversationWithUnechoedOwnReply(
            gmailMessageID: "gmail-batch-spam",
            inboxLabel: inboxLabel
        )

        await messageActions.archiveConversations(conversations: [archived.conversation])

        viewContext.refreshAllObjects()
        await messageActions.reportSpamConversations(conversations: [reported.conversation])
        viewContext.refreshAllObjects()

        let queued = await pendingActionsManager.queuedConversationActions
        XCTAssertEqual(queued.map { $0.type }, [.archiveConversation, .reportSpam])
        XCTAssertEqual(queued.map { $0.messageIds }, [["gmail-batch-archive"], ["gmail-batch-spam"]])
    }

    /// An inbox conversation holding one Gmail message and the user's own
    /// reply as its optimistic row: a local UUID `id` whose RFC Message-ID
    /// encodes it (`OutboundSendDeliveryState.localOptimisticMessageID`).
    private func makeConversationWithUnechoedOwnReply(
        gmailMessageID: String,
        inboxLabel: Label
    ) throws -> (conversation: Conversation, optimisticReply: Message) {
        let conversation = ConversationBuilder()
            .visible()
            .build(in: viewContext)
        let gmailMessage = MessageBuilder()
            .withId(gmailMessageID)
            .inConversation(conversation)
            .build(in: viewContext)
        gmailMessage.addToLabels(inboxLabel)
        let optimisticID = UUID().uuidString
        let optimisticReply = MessageBuilder()
            .withId(optimisticID)
            .fromMe()
            .inConversation(conversation)
            .build(in: viewContext)
        optimisticReply.messageId = MimeBuilder.messageId(forOptimisticMessageID: optimisticID)
        try saveViewContext()
        XCTAssertEqual(
            OutboundSendDeliveryState.localOptimisticMessageID(for: optimisticReply),
            optimisticID
        )
        return (conversation, optimisticReply)
    }

    // MARK: - Archive, Report Spam and star on a background context

    /// A conversation with one INBOX message per date in `inboxDates`
    /// (seconds since 1970, unread where listed) and one message that is not
    /// in the inbox.
    private func makeInboxConversation(
        inboxDates: [TimeInterval],
        unreadDates: Set<TimeInterval> = [],
        idPrefix: String = "inbox"
    ) throws -> (conversation: Conversation, inboxMessages: [Message], otherMessage: Message) {
        let conversation = ConversationBuilder().visible().build(in: viewContext)
        let inboxLabel = try existingOrNewLabel(id: "INBOX")
        let inboxMessages = inboxDates.map { date in
            let builder = MessageBuilder()
                .withId("\(idPrefix)-\(Int(date))")
                .withDate(Date(timeIntervalSince1970: date))
                .inConversation(conversation)
            let message = (unreadDates.contains(date) ? builder.unread() : builder.read()).build(in: viewContext)
            message.addToLabels(inboxLabel)
            return message
        }
        let otherMessage = MessageBuilder()
            .withId("\(idPrefix)-not-in-inbox")
            .withDate(Date(timeIntervalSince1970: 0))
            .read()
            .inConversation(conversation)
            .build(in: viewContext)
        try saveViewContext()
        return (conversation, inboxMessages, otherMessage)
    }

    private func existingOrNewLabel(id: String) throws -> Label {
        let request = Label.fetchRequest()
        request.predicate = LabelPredicates.id(id)
        if let label = try viewContext.fetch(request).first { return label }
        return LabelBuilder().withId(id).build(in: viewContext)
    }

    private func labelIDs(of message: Message) -> Set<String> {
        Set((message.labels ?? []).map(\.id))
    }

    /// Archiving a conversation takes INBOX off every message, stamps every
    /// message (the one that was never in the inbox too), and marks the
    /// conversation archived with an empty inbox rollup, in one save.
    ///
    /// Revert-check: stamping `localModifiedAt` only where INBOX was removed,
    /// in the archive branch of `MessageActions.applyConversationWideMutation`,
    /// leaves `otherMessage` unstamped; dropping
    /// `applyArchivedConversationRollup` there leaves `archivedAt` nil.
    func testArchiveConversation_takesInboxOffEveryMessageStampsThemAllAndArchivesTheConversation() async throws {
        let fixture = try makeInboxConversation(inboxDates: [10, 20, 30], unreadDates: [30])

        await messageActions.archiveConversation(conversation: fixture.conversation)
        viewContext.refreshAllObjects()

        for message in fixture.inboxMessages + [fixture.otherMessage] {
            XCTAssertFalse(labelIDs(of: message).contains("INBOX"), message.id)
            XCTAssertNotNil(message.localModifiedAt, message.id)
        }
        XCTAssertNotNil(fixture.conversation.archivedAt)
        XCTAssertFalse(fixture.conversation.hasInbox)
        XCTAssertEqual(fixture.conversation.inboxUnreadCount, 0)
        XCTAssertNil(fixture.conversation.latestInboxDate)

        let queued = await pendingActionsManager.queuedConversationActions
        XCTAssertEqual(queued.map { $0.type }, [.archiveConversation])
        XCTAssertEqual(queued.first?.sourceConversationId, fixture.conversation.id)
        XCTAssertEqual(
            Set(queued.first?.messageIds ?? []),
            ["inbox-10", "inbox-20", "inbox-30", "inbox-not-in-inbox"]
        )
    }

    /// Report Spam adds SPAM to every message, the one outside the inbox
    /// too, takes INBOX off, and archives the conversation.
    ///
    /// Revert-check: adding SPAM only where INBOX was removed, in the Report
    /// Spam branch of `MessageActions.applyConversationWideMutation`, leaves
    /// `otherMessage` without it.
    func testReportSpamConversation_labelsEveryMessageSpamAndArchivesTheConversation() async throws {
        _ = try existingOrNewLabel(id: "SPAM")
        let fixture = try makeInboxConversation(inboxDates: [10, 20])

        await messageActions.reportSpamConversation(conversation: fixture.conversation)
        viewContext.refreshAllObjects()

        for message in fixture.inboxMessages + [fixture.otherMessage] {
            XCTAssertEqual(labelIDs(of: message), ["SPAM"], message.id)
            XCTAssertNotNil(message.localModifiedAt, message.id)
        }
        XCTAssertNotNil(fixture.conversation.archivedAt)
        XCTAssertFalse(fixture.conversation.hasInbox)

        let queued = await pendingActionsManager.queuedConversationActions
        XCTAssertEqual(queued.map { $0.type }, [.reportSpam])
        XCTAssertEqual(queued.first?.messageIds.count, 3)
    }

    /// A batch archives every conversation in one save and queues one
    /// pending action naming the first conversation and all the messages.
    ///
    /// Revert-check: returning after the first conversation from the loop in
    /// `MessageActions.applyConversationWideMutation` leaves the second in
    /// the inbox and out of the queued action.
    func testArchiveConversations_archivesEveryConversationAndQueuesOneAction() async throws {
        let first = try makeInboxConversation(inboxDates: [10], idPrefix: "first")
        let second = try makeInboxConversation(inboxDates: [20], idPrefix: "second")

        await messageActions.archiveConversations(conversations: [first.conversation, second.conversation])
        viewContext.refreshAllObjects()

        XCTAssertNotNil(first.conversation.archivedAt)
        XCTAssertNotNil(second.conversation.archivedAt)
        XCTAssertFalse(labelIDs(of: second.inboxMessages[0]).contains("INBOX"))
        let queued = await pendingActionsManager.queuedConversationActions
        XCTAssertEqual(queued.count, 1)
        XCTAssertEqual(queued.first?.sourceConversationId, first.conversation.id)
        XCTAssertEqual(
            Set(queued.first?.messageIds ?? []),
            ["first-10", "first-not-in-inbox", "second-20", "second-not-in-inbox"]
        )
    }

    /// The single-conversation archive leaves a conversation with no
    /// messages alone, as it did on the view context.
    ///
    /// Revert-check: dropping the `!mutation.isBatch, messages.isEmpty`
    /// return in `MessageActions.applyConversationWideMutation` archives it.
    func testArchiveConversation_withNoMessages_leavesTheConversationAlone() async throws {
        _ = try existingOrNewLabel(id: "INBOX")
        let conversation = ConversationBuilder().visible().build(in: viewContext)
        try saveViewContext()

        await messageActions.archiveConversation(conversation: conversation)
        viewContext.refreshAllObjects()

        XCTAssertNil(conversation.archivedAt)
        let queued = await pendingActionsManager.queuedConversationActions
        XCTAssertTrue(queued.isEmpty)
    }

    /// A conversation the view context has not saved yet has a temporary
    /// objectID no background context can resolve. The action saves the view
    /// context first, as its own save did when it ran there.
    ///
    /// Revert-check: dropping the `saveIfNeeded` in
    /// `MessageActions.storedObjectIDs` leaves the conversation unarchived
    /// and nothing queued.
    func testArchiveConversation_unsavedConversation_isSavedThenArchived() async throws {
        let inboxLabel = try existingOrNewLabel(id: "INBOX")
        try saveViewContext()
        let conversation = ConversationBuilder().visible().build(in: viewContext)
        let message = MessageBuilder()
            .withId("unsaved-chat-message")
            .inConversation(conversation)
            .build(in: viewContext)
        message.addToLabels(inboxLabel)
        XCTAssertTrue(conversation.objectID.isTemporaryID)

        await messageActions.archiveConversation(conversation: conversation)
        viewContext.refreshAllObjects()

        XCTAssertFalse(conversation.objectID.isTemporaryID)
        XCTAssertNotNil(conversation.archivedAt)
        XCTAssertFalse(labelIDs(of: message).contains("INBOX"))
        let queued = await pendingActionsManager.queuedConversationActions
        XCTAssertEqual(queued.first?.messageIds, ["unsaved-chat-message"])
    }

    /// The local change and the Gmail action go together: when the save
    /// fails, nothing is queued.
    ///
    /// Revert-check: ignoring the result of `save` (the stack's
    /// `saveIfNeeded`, from `MessageActions.makeBackgroundSave`) in
    /// `MessageActions.applyConversationWideMutation` queues the action.
    func testArchiveConversation_doesNotQueuePendingActionWhenLocalSaveFails() async throws {
        let fixture = try makeInboxConversation(inboxDates: [10])
        let actions = MessageActions(
            coreDataStack: FailingSaveCoreDataStack(wrapping: messageActionsStack),
            pendingActionsManager: pendingActionsManager,
            syncRunCoordinator: syncRunCoordinator
        )

        await actions.archiveConversation(conversation: fixture.conversation)
        viewContext.refreshAllObjects()

        XCTAssertNil(fixture.conversation.archivedAt)
        XCTAssertTrue(labelIDs(of: fixture.inboxMessages[0]).contains("INBOX"))
        let queued = await pendingActionsManager.queuedConversationActions
        XCTAssertTrue(queued.isEmpty)
    }

    // MARK: - A second archive, a label that could not be read, a send during an archive

    /// The row of an archived conversation stays in the list until the
    /// archive's save reaches the view context, so it can be swiped again.
    /// The second archive queues behind the first and finds the store
    /// already has it: no message is stamped again, `archivedAt` stays where
    /// the first put it, and Gmail is told once. So does a third, made
    /// after both have finished.
    ///
    /// Revert-check: dropping the `isAlreadyApplied` check from the loop in
    /// `MessageActions.applyConversationWideMutation` queues an
    /// `archiveConversation` action for each of the three, and the third
    /// moves `archivedAt` and every `localModifiedAt`.
    func testArchiveConversation_swipedAgainWhileTheFirstRuns_isDoneOnceAndQueuedOnce() async throws {
        let fixture = try makeInboxConversation(inboxDates: [10, 20], unreadDates: [20])
        let blockingStack = BlockingSaveCoreDataStack(wrapping: messageActionsStack)
        let actions = MessageActions(
            coreDataStack: blockingStack,
            pendingActionsManager: pendingActionsManager,
            rollupMutationSerializer: rollupMutationSerializer,
            syncRunCoordinator: syncRunCoordinator
        )
        let conversation = fixture.conversation
        let messages = fixture.inboxMessages + [fixture.otherMessage]

        let first = Task { @MainActor in
            await actions.archiveConversation(conversation: conversation)
        }
        await waitUntil { blockingStack.saveHasStarted }
        // The first archive is still saving, so the view context has no
        // `archivedAt` and the row is still there to swipe.
        XCTAssertNil(conversation.archivedAt)
        let second = Task { @MainActor in
            await actions.archiveConversation(conversation: conversation)
        }
        blockingStack.releaseSaves()
        await first.value
        await second.value
        viewContext.refreshAllObjects()

        let queuedAfterTwo = await pendingActionsManager.queuedConversationActions
        XCTAssertEqual(queuedAfterTwo.map { $0.type }, [.archiveConversation])
        let archivedAt = try XCTUnwrap(conversation.archivedAt)
        let stamps = messages.map(\.localModifiedAt)
        XCTAssertFalse(stamps.contains(nil))

        await actions.archiveConversation(conversation: conversation)
        viewContext.refreshAllObjects()

        let queued = await pendingActionsManager.queuedConversationActions
        XCTAssertEqual(queued.map { $0.type }, [.archiveConversation])
        XCTAssertEqual(conversation.archivedAt, archivedAt)
        XCTAssertEqual(messages.map(\.localModifiedAt), stamps)
    }

    /// Report Spam twice is done once too: every message already carries
    /// SPAM and none carries INBOX.
    ///
    /// Revert-check: answering false from `MessageActions.isAlreadyApplied`
    /// for `.reportSpam` queues a second `reportSpam` action.
    func testReportSpamConversation_reportedAgain_isDoneOnceAndQueuedOnce() async throws {
        _ = try existingOrNewLabel(id: "SPAM")
        let fixture = try makeInboxConversation(inboxDates: [10, 20])

        await messageActions.reportSpamConversation(conversation: fixture.conversation)
        viewContext.refreshAllObjects()
        let archivedAtAfterFirst = try XCTUnwrap(fixture.conversation.archivedAt)
        await messageActions.reportSpamConversation(conversation: fixture.conversation)
        viewContext.refreshAllObjects()

        let queued = await pendingActionsManager.queuedConversationActions
        XCTAssertEqual(queued.map { $0.type }, [.reportSpam])
        XCTAssertEqual(fixture.conversation.archivedAt, archivedAtAfterFirst)
    }

    /// What "already applied" must not swallow: an archived conversation is
    /// reported as spam afterwards (its messages carry no SPAM yet), and an
    /// archived conversation that has a message back in the inbox is
    /// archived again.
    ///
    /// Revert-check: dropping the SPAM count from
    /// `MessageActions.isAlreadyApplied` skips the spam report, and dropping
    /// its INBOX count skips the second archive: either leaves one queued
    /// action where this expects two.
    func testConversationWideActions_onAnArchivedConversationWithWorkLeft_stillRun() async throws {
        _ = try existingOrNewLabel(id: "SPAM")
        let reported = try makeInboxConversation(inboxDates: [10], idPrefix: "reported")
        await messageActions.archiveConversation(conversation: reported.conversation)
        await messageActions.reportSpamConversation(conversation: reported.conversation)
        viewContext.refreshAllObjects()
        XCTAssertEqual(labelIDs(of: reported.inboxMessages[0]), ["SPAM"])
        XCTAssertEqual(labelIDs(of: reported.otherMessage), ["SPAM"])

        let rearchived = try makeInboxConversation(inboxDates: [10], idPrefix: "rearchived")
        await messageActions.archiveConversation(conversation: rearchived.conversation)
        viewContext.refreshAllObjects()
        // A repair re-homes mail into an archived conversation without
        // touching its `archivedAt` or its rollup.
        rearchived.otherMessage.addToLabels(try existingOrNewLabel(id: "INBOX"))
        try saveViewContext()
        await messageActions.archiveConversation(conversation: rearchived.conversation)
        viewContext.refreshAllObjects()
        XCTAssertFalse(labelIDs(of: rearchived.otherMessage).contains("INBOX"))

        let queued = await pendingActionsManager.queuedConversationActions
        XCTAssertEqual(
            queued.map { $0.type },
            [.archiveConversation, .reportSpam, .archiveConversation, .archiveConversation]
        )
    }

    /// A label that could not be read is not a label the store lacks. Taken
    /// for one, a single archive marked the conversation archived, left
    /// INBOX on every message, and told Gmail to archive them.
    ///
    /// Revert-check: `try?` in place of `try` on the `fetchLabel` calls in
    /// `MessageActions.applyConversationWideMutation` archives the
    /// conversation here and queues the action.
    func testArchiveConversation_inboxLabelCannotBeRead_savesAndQueuesNothing() async throws {
        let fixture = try makeInboxConversation(inboxDates: [10, 20])
        let failingStack = LabelFetchFailingCoreDataStack(
            wrapping: messageActionsStack,
            coordinator: coreDataStack.persistentContainer.persistentStoreCoordinator
        )
        let actions = MessageActions(
            coreDataStack: failingStack,
            pendingActionsManager: pendingActionsManager,
            rollupMutationSerializer: rollupMutationSerializer,
            syncRunCoordinator: syncRunCoordinator
        )

        await actions.archiveConversation(conversation: fixture.conversation)
        viewContext.refreshAllObjects()

        XCTAssertGreaterThan(failingStack.failedLabelFetches, 0)
        XCTAssertNil(fixture.conversation.archivedAt)
        for message in fixture.inboxMessages {
            XCTAssertTrue(labelIDs(of: message).contains("INBOX"), message.id)
            XCTAssertNil(message.localModifiedAt, message.id)
        }
        let queued = await pendingActionsManager.queuedConversationActions
        XCTAssertTrue(queued.isEmpty)
    }

    /// The same for Report Spam and for a star: neither changes anything on
    /// the say-so of a read that failed.
    ///
    /// Revert-check: `try?` on the `fetchLabel` call in
    /// `MessageActions.performStarMutation` stamps the message and queues a
    /// remote star, as "no such label" does.
    func testReportSpamAndStar_labelCannotBeRead_saveAndQueueNothing() async throws {
        _ = try existingOrNewLabel(id: "SPAM")
        _ = try existingOrNewLabel(id: "STARRED")
        let fixture = try makeInboxConversation(inboxDates: [10])
        let failingStack = LabelFetchFailingCoreDataStack(
            wrapping: messageActionsStack,
            coordinator: coreDataStack.persistentContainer.persistentStoreCoordinator
        )
        let actions = MessageActions(
            coreDataStack: failingStack,
            pendingActionsManager: pendingActionsManager,
            rollupMutationSerializer: rollupMutationSerializer,
            syncRunCoordinator: syncRunCoordinator
        )

        await actions.reportSpamConversation(conversation: fixture.conversation)
        await actions.star(message: fixture.inboxMessages[0])
        viewContext.refreshAllObjects()

        XCTAssertGreaterThanOrEqual(failingStack.failedLabelFetches, 2)
        XCTAssertNil(fixture.conversation.archivedAt)
        XCTAssertEqual(labelIDs(of: fixture.inboxMessages[0]), ["INBOX"])
        XCTAssertNil(fixture.inboxMessages[0].localModifiedAt)
        let queuedConversationActions = await pendingActionsManager.queuedConversationActions
        let queuedSingleActions = await pendingActionsManager.queuedSingleActions
        XCTAssertTrue(queuedConversationActions.isEmpty)
        XCTAssertTrue(queuedSingleActions.isEmpty)
    }

    /// Archive takes its conversations' turns and not the cleanup-sensitive
    /// gate, which every send, draft save and cleanup pass queues on. Here
    /// something else holds the gate, as a full cleanup does for the whole
    /// of its run at the end of an initial sync, and the archive is done
    /// while it is still held.
    ///
    /// Revert-check: asking for the gate with the conversations' turns in
    /// `MessageActions.performConversationWideMutation` leaves the archive
    /// queued behind the holder, and the wait for it times out.
    func testArchiveConversation_whileSomethingElseHoldsTheCleanupSensitiveGate_doesNotWaitForIt() async throws {
        let fixture = try makeInboxConversation(inboxDates: [10])
        let conversation = fixture.conversation
        let actions = self.messageActions!
        let serializer = self.rollupMutationSerializer!

        let gateIsHeld = AccountBoundaryFlag()
        let releaseGate = AccountBoundaryFlag()
        let cleanup = Task {
            await serializer.performCleanupSensitiveMutation(
                onEnqueued: { gateIsHeld.set() },
                operation: {
                    while !releaseGate.isSet {
                        try? await Task.sleep(nanoseconds: 5_000_000)
                    }
                }
            )
        }
        await waitUntil { gateIsHeld.isSet }

        let archiveFinished = AccountBoundaryFlag()
        let archive = Task { @MainActor in
            await actions.archiveConversation(conversation: conversation)
            archiveFinished.set()
        }
        await waitUntil { archiveFinished.isSet }
        XCTAssertFalse(releaseGate.isSet)

        releaseGate.set()
        await cleanup.value
        await archive.value
        viewContext.refreshAllObjects()
        XCTAssertNotNil(conversation.archivedAt)
        let queued = await pendingActionsManager.queuedConversationActions
        XCTAssertEqual(queued.map { $0.type }, [.archiveConversation])
    }

    /// The other direction: while an archive is still saving, the gate is
    /// free, so a send or a draft save in any other chat is not kept
    /// waiting for it.
    ///
    /// Revert-check: asking for the gate with the conversations' turns in
    /// `MessageActions.performConversationWideMutation` queues the gated
    /// block behind the archive, and the wait for it times out.
    func testArchiveConversation_whileItIsSaving_leavesTheCleanupSensitiveGateFree() async throws {
        let fixture = try makeInboxConversation(inboxDates: [10])
        let blockingStack = BlockingSaveCoreDataStack(wrapping: messageActionsStack)
        let actions = MessageActions(
            coreDataStack: blockingStack,
            pendingActionsManager: pendingActionsManager,
            rollupMutationSerializer: rollupMutationSerializer,
            syncRunCoordinator: syncRunCoordinator
        )
        let conversation = fixture.conversation
        let serializer = self.rollupMutationSerializer!

        let archive = Task { @MainActor in
            await actions.archiveConversation(conversation: conversation)
        }
        await waitUntil { blockingStack.saveHasStarted }

        let gatedBlockRan = AccountBoundaryFlag()
        let gatedBlock = Task {
            await serializer.performCleanupSensitiveMutation(operation: { gatedBlockRan.set() })
        }
        await waitUntil { gatedBlockRan.isSet }

        blockingStack.releaseSaves()
        await archive.value
        await gatedBlock.value
        let queued = await pendingActionsManager.queuedConversationActions
        XCTAssertEqual(queued.map { $0.type }, [.archiveConversation])
    }

    /// A send to the conversation being archived is the one thing that does
    /// wait for the archive. It takes the conversation's turn inside the
    /// gate, so it runs wholly after the archive, reads the store's archive
    /// state there, and reactivates the conversation, as it did when the
    /// archive ran on the view context. Created while the archive was still
    /// saving, it read the conversation as active, anchored to it, and was
    /// archived with it.
    ///
    /// Revert-check: creating the message in
    /// `GmailSendService.createOptimisticMessage` without
    /// `performThrowingAnchoredSendMutation` never queues the send for the
    /// turn, and the wait for `sendIsQueued` times out. Dropping
    /// `adoptStoredArchiveState` there has the send read a nil `archivedAt`
    /// (this suite's view context merges no save by itself) and leaves the
    /// conversation archived with the send in it.
    func testArchiveConversation_sendToItWhileItIsSaving_takesItsTurnAfterTheArchiveAndReactivates() async throws {
        let recipient = "friend@example.com"
        let participantHash = calculateParticipantHash(from: [normalizedEmail(recipient)])
        let conversation = ConversationBuilder()
            .withParticipantHash(participantHash)
            .visible()
            .build(in: viewContext)
        let received = MessageBuilder()
            .withId("received")
            .inConversation(conversation)
            .build(in: viewContext)
        received.addToLabels(try existingOrNewLabel(id: "INBOX"))
        try saveViewContext()
        let conversationID = conversation.objectID

        let blockingStack = BlockingSaveCoreDataStack(wrapping: messageActionsStack)
        let actions = MessageActions(
            coreDataStack: blockingStack,
            pendingActionsManager: pendingActionsManager,
            rollupMutationSerializer: rollupMutationSerializer,
            syncRunCoordinator: syncRunCoordinator
        )
        let sendIsQueued = AccountBoundaryFlag()
        let sendService = GmailSendService(
            viewContext: viewContext,
            conversationMutationSerializer: rollupMutationSerializer,
            anchorTurnDidEnqueue: { sendIsQueued.set() }
        )

        let archive = Task { @MainActor in
            await actions.archiveConversation(conversation: conversation)
        }
        await waitUntil { blockingStack.saveHasStarted }
        let send = Task { @MainActor in
            try await sendService.createOptimisticMessage(
                to: [recipient],
                body: "sent during the archive",
                optimisticConversation: .participantHash(participantHash)
            )
        }
        await waitUntil { sendIsQueued.isSet }
        // Queued behind an archive that cannot finish yet: nothing of the
        // send exists.
        XCTAssertEqual(conversation.messages?.count, 1)

        blockingStack.releaseSaves()
        await archive.value
        let handle = try await send.value

        let sent = try XCTUnwrap(sendService.fetchMessageSync(byID: handle.optimisticMessageID))
        XCTAssertEqual(sent.conversation?.objectID, conversationID)
        XCTAssertNil(conversation.archivedAt)
        let stored = try await storedArchiveState(of: conversationID, inboxMessageID: received.objectID)
        XCTAssertNil(stored.archivedAt, "The send was archived with the conversation")
        XCTAssertFalse(stored.messageIsInInbox, "The archive did not run")
        let queued = await pendingActionsManager.queuedConversationActions
        XCTAssertEqual(queued.map { $0.type }, [.archiveConversation])
    }

    /// What the store has for a conversation's `archivedAt` and for whether
    /// one of its messages still carries INBOX, read on a context of its own.
    private func storedArchiveState(
        of conversationID: NSManagedObjectID,
        inboxMessageID: NSManagedObjectID
    ) async throws -> (archivedAt: Date?, messageIsInInbox: Bool) {
        let context = coreDataStack.newBackgroundContext()
        return try await context.perform {
            let conversation = try XCTUnwrap(try context.existingObject(with: conversationID) as? Conversation)
            let message = try XCTUnwrap(try context.existingObject(with: inboxMessageID) as? Message)
            return (conversation.archivedAt, message.labels?.contains(where: { $0.id == "INBOX" }) == true)
        }
    }

    /// The chat-open snapshot's fetch is started when it is asked for and
    /// runs with no help from the main actor, which at chat open is laying
    /// the transcript out. A message saved after the fetch is not in it.
    ///
    /// Revert-check: `Task` in place of `Task.detached` in
    /// `MessageActions.startUnreadInboxSnapshot` inherits the main actor,
    /// and no fetch runs for as long as this test holds the main thread.
    func testStartUnreadInboxSnapshot_fetchesWithoutTheMainActorAndLeavesOutALaterMessage() async throws {
        let countingStack = FetchCountingMessageActionsStack(
            wrapping: messageActionsStack,
            coordinator: coreDataStack.persistentContainer.persistentStoreCoordinator
        )
        let actions = MessageActions(
            coreDataStack: countingStack,
            pendingActionsManager: pendingActionsManager,
            rollupMutationSerializer: rollupMutationSerializer,
            syncRunCoordinator: syncRunCoordinator
        )
        let conversation = ConversationBuilder().visible().build(in: viewContext)
        let inboxLabel = LabelBuilder().inbox().build(in: viewContext)
        let unreadAtOpen = MessageBuilder().withId("unread-at-open").unread()
            .inConversation(conversation).build(in: viewContext)
        unreadAtOpen.addToLabels(inboxLabel)
        try saveViewContext()

        let snapshot = actions.startUnreadInboxSnapshot(conversationID: conversation.objectID)
        // No await between the call and here: nothing has run on the main
        // actor since the snapshot was asked for.
        XCTAssertTrue(
            holdThisThread(until: { countingStack.fetchCount(ofEntity: "Message") >= 1 }),
            "The snapshot's fetch waited for the main actor"
        )

        let savedLater = MessageBuilder().withId("saved-after-the-snapshot").unread()
            .inConversation(conversation).build(in: viewContext)
        savedLater.addToLabels(inboxLabel)
        try saveViewContext()

        let messageIDs = await snapshot.value
        XCTAssertEqual(messageIDs, [unreadAtOpen.objectID])
    }

    /// Archiving single messages, newest first, keeps the conversation's
    /// rollup right at each step: the next-newest INBOX message becomes the
    /// latest, the unread count follows, and the last archive empties it.
    ///
    /// Revert-check: dropping `NOT (SELF IN %@)` from
    /// `MessageActions.storedInboxPredicate` counts the message just
    /// archived, which the store still has in the inbox: the first archive
    /// leaves the latest date at 30 and the last leaves `hasInbox` true.
    func testArchiveMessage_recomputesTheConversationsInboxRollupAtEachStep() async throws {
        let fixture = try makeInboxConversation(inboxDates: [10, 20, 30], unreadDates: [10, 30])
        let conversation = fixture.conversation
        let (oldest, middle, newest) = (fixture.inboxMessages[0], fixture.inboxMessages[1], fixture.inboxMessages[2])

        await messageActions.archive(message: newest)
        viewContext.refreshAllObjects()
        XCTAssertFalse(labelIDs(of: newest).contains("INBOX"))
        XCTAssertNotNil(newest.localModifiedAt)
        XCTAssertTrue(conversation.hasInbox)
        XCTAssertEqual(conversation.inboxUnreadCount, 1)
        XCTAssertEqual(conversation.latestInboxDate, Date(timeIntervalSince1970: 20))
        XCTAssertNil(conversation.archivedAt)

        await messageActions.archive(message: oldest)
        viewContext.refreshAllObjects()
        XCTAssertTrue(conversation.hasInbox)
        XCTAssertEqual(conversation.inboxUnreadCount, 0)
        XCTAssertEqual(conversation.latestInboxDate, Date(timeIntervalSince1970: 20))

        await messageActions.archive(message: middle)
        viewContext.refreshAllObjects()
        XCTAssertFalse(conversation.hasInbox)
        XCTAssertEqual(conversation.inboxUnreadCount, 0)
        XCTAssertNil(conversation.latestInboxDate)

        let queued = await pendingActionsManager.queuedSingleActions
        XCTAssertEqual(queued.map { $0.type }, [.archive, .archive, .archive])
        XCTAssertEqual(queued.map { $0.messageId }, ["inbox-30", "inbox-10", "inbox-20"])
    }

    /// Marking the newest INBOX message unread and read again goes through
    /// the same bounded rollup: the changed message is counted from memory
    /// and the rest from the store.
    ///
    /// Revert-check: dropping the loop over `changedMessages` in
    /// `MessageActions.applyInboxRollup` loses the changed message: the
    /// unread count stays 0 after the mark-unread, and the latest date drops
    /// to 20.
    func testMarkConversationAsUnread_thenRead_keepsTheRollupThroughTheBoundedQueries() async throws {
        let fixture = try makeInboxConversation(inboxDates: [10, 20, 30])
        let conversation = fixture.conversation
        let newest = fixture.inboxMessages[2]

        await messageActions.markConversationAsUnread(conversation: conversation)
        viewContext.refreshAllObjects()
        XCTAssertTrue(newest.isUnread)
        XCTAssertTrue(conversation.hasInbox)
        XCTAssertEqual(conversation.inboxUnreadCount, 1)
        XCTAssertEqual(conversation.latestInboxDate, Date(timeIntervalSince1970: 30))

        await messageActions.markAsRead(message: newest)
        viewContext.refreshAllObjects()
        XCTAssertFalse(newest.isUnread)
        XCTAssertEqual(conversation.inboxUnreadCount, 0)
        XCTAssertEqual(conversation.latestInboxDate, Date(timeIntervalSince1970: 30))
    }

    /// The point of the move: archiving a message reads none of its labels
    /// on the view context. There, reading the message's labels and removing
    /// INBOX loaded the INBOX label and, through its inverse, every message
    /// in the inbox.
    ///
    /// Revert-check: using `coreDataStack.viewContext` for the context in
    /// `MessageActions.performArchive` fires the message's labels fault
    /// here. (Asserting that no `Label` is registered afterwards does not
    /// catch it: once INBOX is removed and saved nothing retains the label,
    /// and the view context lets it go.)
    func testArchiveMessage_readsNoLabelsOnTheViewContext() async throws {
        let fixture = try makeInboxConversation(inboxDates: [10, 20])
        let messageID = fixture.inboxMessages[1].objectID
        viewContext.reset()
        let message = try XCTUnwrap(viewContext.existingObject(with: messageID) as? Message)
        XCTAssertTrue(message.hasFault(forRelationshipNamed: "labels"))

        await messageActions.archive(message: message)

        XCTAssertTrue(message.hasFault(forRelationshipNamed: "labels"))
        let queued = await pendingActionsManager.queuedSingleActions
        XCTAssertEqual(queued.map { $0.messageId }, ["inbox-20"])
    }

    func testStar_doesNotQueuePendingActionWhenLocalSaveFails() async throws {
        _ = LabelBuilder().starred().build(in: viewContext)
        let message = MessageBuilder()
            .withId("message-save-fails")
            .build(in: viewContext)
        try saveViewContext()

        let failingStack = FailingSaveCoreDataStack(wrapping: messageActionsStack)
        let actions = MessageActions(
            coreDataStack: failingStack,
            pendingActionsManager: pendingActionsManager,
            syncRunCoordinator: syncRunCoordinator
        )

        await actions.star(message: message)
        viewContext.refreshAllObjects()

        // The optimistic in-memory change may still apply, but a remote sync must
        // not be queued when we couldn't persist the change locally.
        let queuedActions = await pendingActionsManager.queuedSingleActions
        XCTAssertTrue(queuedActions.isEmpty, "Remote star must not be queued when the local save fails")
    }

    func testMarkMessagesAsReadBatch_marksSnapshotUnreadMessagesOffMainThread() async throws {
        let conversation = ConversationBuilder()
            .visible()
            .withUnreadCount(2)
            .build(in: viewContext)
        let inboxLabel = LabelBuilder().inbox().build(in: viewContext)
        let includedMessage = MessageBuilder()
            .withId("message-to-read")
            .unread()
            .inConversation(conversation)
            .build(in: viewContext)
        includedMessage.addToLabels(inboxLabel)
        let excludedMessage = MessageBuilder()
            .withId("draft-message")
            .unread()
            .inConversation(conversation)
            .build(in: viewContext)
        let draftLabel = LabelBuilder().draft().build(in: viewContext)
        excludedMessage.addToLabels(draftLabel)

        let nonInboxMessage = MessageBuilder()
            .withId("sent-message")
            .unread()
            .inConversation(conversation)
            .build(in: viewContext)
        try saveViewContext()
        let messageIDs = await messageActions.snapshotUnreadInboxMessageObjectIDs(
            conversationID: conversation.objectID
        )

        await messageActions.markMessagesAsReadBatch(
            messageIDs: messageIDs,
            conversationID: conversation.objectID
        )

        await waitUntil {
            self.viewContext.refreshAllObjects()
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
            .build(in: viewContext)
        let inboxLabel = LabelBuilder().inbox().build(in: viewContext)
        let message = MessageBuilder()
            .withId("serialized-single-read")
            .unread()
            .inConversation(conversation)
            .build(in: viewContext)
        message.addToLabels(inboxLabel)
        try saveViewContext()

        await messageActions.markAsRead(message: message)

        await waitUntil {
            self.viewContext.refreshAllObjects()
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
            .build(in: viewContext)
        let inboxLabel = LabelBuilder().inbox().build(in: viewContext)
        let message = MessageBuilder()
            .withId("serialized-object-id-read")
            .unread()
            .inConversation(conversation)
            .build(in: viewContext)
        message.addToLabels(inboxLabel)
        try saveViewContext()

        await messageActions.markAsRead(messageID: message.objectID)

        await waitUntil {
            self.viewContext.refreshAllObjects()
            return !message.isUnread && conversation.inboxUnreadCount == 0
        }

        let queuedActions = await pendingActionsManager.queuedSingleActions
        XCTAssertEqual(queuedActions.map(\.type), [.markRead])
        XCTAssertEqual(queuedActions.first?.messageId, message.id)
    }

    func testMarkMessagesAsReadBatchRevalidatesInboxAndConversation() async throws {
        let sourceConversation = ConversationBuilder().visible().build(in: viewContext)
        let otherConversation = ConversationBuilder().visible().build(in: viewContext)
        let inboxLabel = LabelBuilder().inbox().build(in: viewContext)
        let message = MessageBuilder()
            .withId("revalidate-read-target")
            .unread()
            .inConversation(sourceConversation)
            .build(in: viewContext)
        message.addToLabels(inboxLabel)
        try saveViewContext()

        await messageActions.markMessagesAsReadBatch(
            messageIDs: [message.objectID],
            conversationID: otherConversation.objectID
        )

        viewContext.refreshAllObjects()
        XCTAssertTrue(message.isUnread)
        let queuedConversationActions = await pendingActionsManager.queuedConversationActions
        XCTAssertTrue(queuedConversationActions.isEmpty)
    }

    func testMarkMessagesAsReadBatch_keepsLaterUnreadInboxMessageUnreadAndCounted() async throws {
        let conversation = ConversationBuilder()
            .visible()
            .withUnreadCount(1)
            .build(in: viewContext)
        let inboxLabel = LabelBuilder().inbox().build(in: viewContext)
        let initialMessage = MessageBuilder()
            .withId("message-visible-at-open")
            .unread()
            .inConversation(conversation)
            .build(in: viewContext)
        initialMessage.addToLabels(inboxLabel)
        try saveViewContext()

        let messageIDsAtOpen = await messageActions.snapshotUnreadInboxMessageObjectIDs(
            conversationID: conversation.objectID
        )

        let laterMessage = MessageBuilder()
            .withId("message-arrived-later")
            .unread()
            .inConversation(conversation)
            .build(in: viewContext)
        laterMessage.addToLabels(inboxLabel)
        conversation.inboxUnreadCount = 2
        try saveViewContext()

        await messageActions.markMessagesAsReadBatch(
            messageIDs: messageIDsAtOpen,
            conversationID: conversation.objectID
        )

        await waitUntil {
            self.viewContext.refreshAllObjects()
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
            .build(in: viewContext)
        let inboxLabel = LabelBuilder().inbox().build(in: viewContext)
        let firstMessage = MessageBuilder()
            .withId("first-concurrent-read")
            .unread()
            .inConversation(conversation)
            .build(in: viewContext)
        firstMessage.addToLabels(inboxLabel)
        let secondMessage = MessageBuilder()
            .withId("second-concurrent-read")
            .unread()
            .inConversation(conversation)
            .build(in: viewContext)
        secondMessage.addToLabels(inboxLabel)
        try saveViewContext()

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

        viewContext.refreshAllObjects()
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
            .build(in: viewContext)
        let inboxLabel = LabelBuilder().inbox().build(in: viewContext)
        let message = MessageBuilder()
            .withId("serialized-pending-action-order")
            .read()
            .inConversation(conversation)
            .build(in: viewContext)
        message.addToLabels(inboxLabel)
        try saveViewContext()

        let orderingManager = BlockingReadStatePendingActionsManager()
        let serializer = ConversationRollupMutationSerializer()
        let actions = MessageActions(
            coreDataStack: messageActionsStack,
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
            .build(in: viewContext)
        let inboxLabel = LabelBuilder().inbox().build(in: viewContext)
        let message = MessageBuilder()
            .withId("read-during-sync-rollup")
            .unread()
            .inConversation(conversation)
            .build(in: viewContext)
        message.addToLabels(inboxLabel)
        try saveViewContext()

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
            .build(in: viewContext)
        let inboxLabel = LabelBuilder().inbox().build(in: viewContext)
        let message = MessageBuilder()
            .withId("read-before-stale-sync-save")
            .unread()
            .inConversation(conversation)
            .build(in: viewContext)
        message.addToLabels(inboxLabel)
        try saveViewContext()
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
            .build(in: viewContext)
        let inboxLabel = LabelBuilder().inbox().build(in: viewContext)
        let firstMessage = MessageBuilder()
            .withId("inbox-unread-1")
            .unread()
            .inConversation(conversation)
            .build(in: viewContext)
        firstMessage.addToLabels(inboxLabel)
        let secondMessage = MessageBuilder()
            .withId("inbox-unread-2")
            .unread()
            .inConversation(conversation)
            .build(in: viewContext)
        secondMessage.addToLabels(inboxLabel)
        let nonInboxMessage = MessageBuilder()
            .withId("sent-unread")
            .unread()
            .inConversation(conversation)
            .build(in: viewContext)
        try saveViewContext()

        await messageActions.markConversationAsRead(conversation: conversation)

        await waitUntil {
            self.viewContext.refreshAllObjects()
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
            .build(in: viewContext)
        let nonInboxMessage = MessageBuilder()
            .withId("sent-message")
            .read()
            .inConversation(conversation)
            .build(in: viewContext)
        try saveViewContext()

        await messageActions.markConversationAsUnread(conversation: conversation)

        XCTAssertFalse(nonInboxMessage.isUnread)
        XCTAssertEqual(conversation.inboxUnreadCount, 0)
        let queuedActions = await pendingActionsManager.queuedSingleActions
        XCTAssertTrue(queuedActions.isEmpty)
    }

    /// The chat-open snapshot names this conversation's unread INBOX messages
    /// and nothing else: not another conversation's unread mail, and not the
    /// read or non-INBOX messages of this one.
    ///
    /// Revert-check: dropping `conversation == %@` from
    /// `MessagePredicates.unreadInInbox` adds "other-chat-unread".
    func testSnapshotUnreadInboxMessageObjectIDs_namesOnlyThisConversationsUnreadInboxMessages() async throws {
        let conversation = ConversationBuilder().visible().build(in: viewContext)
        let otherConversation = ConversationBuilder().visible().build(in: viewContext)
        let inboxLabel = LabelBuilder().inbox().build(in: viewContext)

        func message(_ id: String, unread: Bool, inInbox: Bool, in conversation: Conversation) -> Message {
            let builder = MessageBuilder().withId(id).inConversation(conversation)
            let message = (unread ? builder.unread() : builder.read()).build(in: viewContext)
            if inInbox { message.addToLabels(inboxLabel) }
            return message
        }
        let firstUnread = message("first-unread", unread: true, inInbox: true, in: conversation)
        let secondUnread = message("second-unread", unread: true, inInbox: true, in: conversation)
        _ = message("read-inbox", unread: false, inInbox: true, in: conversation)
        _ = message("unread-not-in-inbox", unread: true, inInbox: false, in: conversation)
        _ = message("other-chat-unread", unread: true, inInbox: true, in: otherConversation)
        try saveViewContext()

        let snapshot = await messageActions.snapshotUnreadInboxMessageObjectIDs(
            conversationID: conversation.objectID
        )

        XCTAssertEqual(Set(snapshot), [firstUnread.objectID, secondUnread.objectID])
        XCTAssertEqual(snapshot.count, 2)
    }

    /// An unsaved conversation has a temporary objectID and no stored
    /// messages; its snapshot is empty.
    ///
    /// HONEST SCOPE: this pins the answer, not the guard. Without the
    /// `isTemporaryID` guard the fetch is asked about an ID the store has no
    /// row for, and what Core Data does with that is not something the app
    /// should depend on.
    func testSnapshotUnreadInboxMessageObjectIDs_unsavedConversation_isEmpty() async throws {
        let conversation = ConversationBuilder().visible().build(in: viewContext)
        XCTAssertTrue(conversation.objectID.isTemporaryID)

        let snapshot = await messageActions.snapshotUnreadInboxMessageObjectIDs(
            conversationID: conversation.objectID
        )

        XCTAssertEqual(snapshot, [])
    }

    /// A batch larger than one fetch chunk marks every message, recomputes
    /// the unread count once, and queues one conversation action naming them
    /// all in the order they were passed.
    ///
    /// Revert-check: making `MessageActions.fetchMessagesWithLabels` stop
    /// after its first chunk leaves the last three messages unread and out
    /// of the queued action.
    func testMarkMessagesAsReadBatch_moreThanOneFetchChunk_marksEveryMessageAndQueuesOneAction() async throws {
        let messageCount = MessageActions.markReadFetchChunkSize + 3
        let conversation = ConversationBuilder()
            .visible()
            .withUnreadCount(Int32(messageCount))
            .build(in: viewContext)
        let inboxLabel = LabelBuilder().inbox().build(in: viewContext)
        let messages = (0..<messageCount).map { index in
            let message = MessageBuilder()
                .withId(String(format: "chunked-%04d", index))
                .unread()
                .inConversation(conversation)
                .build(in: viewContext)
            message.addToLabels(inboxLabel)
            return message
        }
        try saveViewContext()

        await messageActions.markMessagesAsReadBatch(
            messageIDs: messages.map(\.objectID),
            conversationID: conversation.objectID
        )

        viewContext.refreshAllObjects()
        XCTAssertEqual(messages.filter(\.isUnread).map(\.id), [])
        XCTAssertEqual(conversation.inboxUnreadCount, 0)
        let queuedConversationActions = await pendingActionsManager.queuedConversationActions
        XCTAssertEqual(queuedConversationActions.count, 1)
        XCTAssertEqual(queuedConversationActions.first?.messageIds, messages.map(\.id))
    }

    func testExactUnreadInboxSnapshotDoesNotIncludeUnrelatedOrNonInboxMessages() throws {
        let conversation = ConversationBuilder()
            .visible()
            .withUnreadCount(2)
            .build(in: viewContext)
        let inboxLabel = LabelBuilder().inbox().build(in: viewContext)
        let eligibleArrival = MessageBuilder()
            .withId("eligible-arrival")
            .unread()
            .inConversation(conversation)
            .build(in: viewContext)
        eligibleArrival.addToLabels(inboxLabel)
        let unrelatedUnread = MessageBuilder()
            .withId("preserved-unread")
            .unread()
            .inConversation(conversation)
            .build(in: viewContext)
        unrelatedUnread.addToLabels(inboxLabel)
        let nonInboxArrival = MessageBuilder()
            .withId("non-inbox-arrival")
            .unread()
            .inConversation(conversation)
            .build(in: viewContext)
        let readInboxArrival = MessageBuilder()
            .withId("read-inbox-arrival")
            .read()
            .inConversation(conversation)
            .build(in: viewContext)
        readInboxArrival.addToLabels(inboxLabel)
        try saveViewContext()

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
            .build(in: viewContext)
        let inboxLabel = LabelBuilder().inbox().build(in: viewContext)
        let message = MessageBuilder()
            .withId("message-to-keep-unread")
            .unread()
            .inConversation(conversation)
            .build(in: viewContext)
        message.addToLabels(inboxLabel)
        try saveViewContext()

        let failingActions = MessageActions(
            coreDataStack: messageActionsStack,
            pendingActionsManager: pendingActionsManager,
            unreadInboxMessageCounter: { _, _ in
                throw MessageActionsTestError.unreadCountFailed
            },
            syncRunCoordinator: syncRunCoordinator
        )
        let messageIDs = await failingActions.snapshotUnreadInboxMessageObjectIDs(
            conversationID: conversation.objectID
        )

        await failingActions.markMessagesAsReadBatch(
            messageIDs: messageIDs,
            conversationID: conversation.objectID
        )

        viewContext.refreshAllObjects()
        XCTAssertTrue(message.isUnread)
        XCTAssertEqual(conversation.inboxUnreadCount, 1)
        let queuedActions = await pendingActionsManager.queuedConversationActions
        XCTAssertTrue(queuedActions.isEmpty)
    }

    // MARK: - The action row commits in the save of the change it describes

    // Until 2026-11-27 each action saved its change on a background context and
    // the manager inserted the `PendingAction` row afterwards, on the view
    // context, in a save of its own: a process killed between the two kept a
    // change Gmail never received, which label reconciliation undid on recent
    // mail once the 30-minute marker lapsed (architecture review 2026-11,
    // outbound-and-actions#4). These tests read what each save committed from
    // `NSManagedObjectContextDidSave` and what the store holds afterwards; the
    // suite's mock manager inserts nothing, so a row in the store is the one
    // `MessageActions` staged.

    /// Archiving one message commits the INBOX removal and its `archive` row
    /// in one save, the row dated no earlier than the message's marker, and
    /// the manager is told of the row afterwards.
    ///
    /// Revert-check: committing the row in a second save after the first in
    /// `MessageActions.performArchive` (the combined save split in two)
    /// records two saves, the first without the row.
    func testArchiveMessage_changeAndItsActionRow_commitInOneSave() async throws {
        let fixture = try makeInboxConversation(inboxDates: [10], idPrefix: "one-save-archive")
        let message = fixture.inboxMessages[0]
        let recorder = SaveRecorder(coordinator: coreDataStack.persistentContainer.persistentStoreCoordinator)

        await messageActions.archive(message: message)
        let saves = recorder.stop()

        XCTAssertEqual(saves.count, 1, "The change and its action row are one save")
        XCTAssertEqual(saves.first?.insertedEntityNames, ["PendingAction"])
        XCTAssertEqual(saves.first?.updatedObjectIDs.contains(message.objectID), true)

        let rows = try await storedPendingActions()
        XCTAssertEqual(rows.count, 1)
        let row = try XCTUnwrap(rows.first)
        XCTAssertEqual(row.actionType, PendingAction.ActionType.archive.rawValue)
        XCTAssertEqual(row.messageId, "one-save-archive-10")
        XCTAssertEqual(row.status, "pending")
        let stored = try await storedMessageState(of: message.objectID)
        XCTAssertFalse(stored.labelIDs.contains("INBOX"))
        let marker = try XCTUnwrap(stored.localModifiedAt)
        XCTAssertGreaterThanOrEqual(row.createdAt, marker)

        let queued = await pendingActionsManager.queuedSingleActions
        XCTAssertEqual(queued.map(\.type), [.archive])
        XCTAssertEqual(queued.map(\.messageId), ["one-save-archive-10"])
    }

    /// Marking one message unread commits the read state, the rollup and the
    /// `markUnread` row in one save. This path saves with `saveOrLog`, not
    /// the stack's save, so it is checked on its own.
    ///
    /// Revert-check: committing the row in a second save after the first in
    /// `MessageActions.performReadStateMutation` records two saves, the first
    /// without the row.
    func testMarkAsUnread_changeAndItsActionRow_commitInOneSave() async throws {
        let fixture = try makeInboxConversation(inboxDates: [10], idPrefix: "one-save-unread")
        let message = fixture.inboxMessages[0]
        let recorder = SaveRecorder(coordinator: coreDataStack.persistentContainer.persistentStoreCoordinator)

        await messageActions.markAsUnread(message: message)
        let saves = recorder.stop()

        XCTAssertEqual(saves.count, 1, "The change and its action row are one save")
        XCTAssertEqual(saves.first?.insertedEntityNames, ["PendingAction"])
        XCTAssertEqual(saves.first?.updatedObjectIDs.contains(message.objectID), true)
        XCTAssertEqual(saves.first?.updatedObjectIDs.contains(fixture.conversation.objectID), true)

        let rows = try await storedPendingActions()
        XCTAssertEqual(rows.count, 1)
        let row = try XCTUnwrap(rows.first)
        XCTAssertEqual(row.actionType, PendingAction.ActionType.markUnread.rawValue)
        XCTAssertEqual(row.messageId, "one-save-unread-10")
        let stored = try await storedMessageState(of: message.objectID)
        XCTAssertTrue(stored.isUnread)
        let marker = try XCTUnwrap(stored.localModifiedAt)
        XCTAssertGreaterThanOrEqual(row.createdAt, marker)

        let queued = await pendingActionsManager.queuedSingleActions
        XCTAssertEqual(queued.map(\.type), [.markUnread])
    }

    /// Opening a chat's unread mail marks the batch read and commits one
    /// `markRead` row naming the marked messages in the same save as the
    /// marks and the recount.
    ///
    /// Revert-check: committing the row in a second save after the first in
    /// `MessageActions.performMarkMessagesAsReadBatch` records two saves, the
    /// first without the row.
    func testMarkConversationAsRead_batchAndItsActionRow_commitInOneSave() async throws {
        let fixture = try makeInboxConversation(
            inboxDates: [10, 20],
            unreadDates: [10, 20],
            idPrefix: "one-save-read"
        )
        let recorder = SaveRecorder(coordinator: coreDataStack.persistentContainer.persistentStoreCoordinator)

        await messageActions.markConversationAsRead(conversation: fixture.conversation)
        let saves = recorder.stop()

        XCTAssertEqual(saves.count, 1, "The batch and its action row are one save")
        XCTAssertEqual(saves.first?.insertedEntityNames, ["PendingAction"])
        for message in fixture.inboxMessages {
            XCTAssertEqual(saves.first?.updatedObjectIDs.contains(message.objectID), true)
        }

        let rows = try await storedPendingActions()
        XCTAssertEqual(rows.count, 1)
        let row = try XCTUnwrap(rows.first)
        XCTAssertEqual(row.actionType, PendingAction.ActionType.markRead.rawValue)
        XCTAssertNil(row.messageId)
        XCTAssertEqual(row.conversationId, fixture.conversation.id)
        XCTAssertEqual(Set(row.payloadMessageIDs), ["one-save-read-10", "one-save-read-20"])
        for message in fixture.inboxMessages {
            let stored = try await storedMessageState(of: message.objectID)
            XCTAssertFalse(stored.isUnread)
            XCTAssertGreaterThanOrEqual(row.createdAt, try XCTUnwrap(stored.localModifiedAt))
        }

        let queued = await pendingActionsManager.queuedConversationActions
        XCTAssertEqual(queued.map(\.type), [.markRead])
        XCTAssertEqual(Set(queued.first?.messageIds ?? []), ["one-save-read-10", "one-save-read-20"])
    }

    /// Archiving a conversation commits every message's change, the archived
    /// rollup and the `archiveConversation` row in one save.
    ///
    /// Revert-check: committing the row in a second save after the first in
    /// `MessageActions.applyConversationWideMutation` records two saves, the
    /// first without the row; dating the row a second before the markers
    /// there fails the `createdAt` check.
    func testArchiveConversation_changeAndItsActionRow_commitInOneSave() async throws {
        let fixture = try makeInboxConversation(inboxDates: [10, 20], idPrefix: "one-save-conversation")
        let recorder = SaveRecorder(coordinator: coreDataStack.persistentContainer.persistentStoreCoordinator)

        await messageActions.archiveConversation(conversation: fixture.conversation)
        let saves = recorder.stop()

        XCTAssertEqual(saves.count, 1, "The change and its action row are one save")
        XCTAssertEqual(saves.first?.insertedEntityNames, ["PendingAction"])
        XCTAssertEqual(saves.first?.updatedObjectIDs.contains(fixture.conversation.objectID), true)

        let rows = try await storedPendingActions()
        XCTAssertEqual(rows.count, 1)
        let row = try XCTUnwrap(rows.first)
        XCTAssertEqual(row.actionType, PendingAction.ActionType.archiveConversation.rawValue)
        XCTAssertEqual(row.conversationId, fixture.conversation.id)
        let allMessages = fixture.inboxMessages + [fixture.otherMessage]
        XCTAssertEqual(Set(row.payloadMessageIDs), Set(allMessages.map(\.id)))
        for message in allMessages {
            let stored = try await storedMessageState(of: message.objectID)
            XCTAssertFalse(stored.labelIDs.contains("INBOX"))
            XCTAssertGreaterThanOrEqual(row.createdAt, try XCTUnwrap(stored.localModifiedAt))
        }

        let queued = await pendingActionsManager.queuedConversationActions
        XCTAssertEqual(queued.map(\.type), [.archiveConversation])
    }

    /// A failed save keeps neither the archive nor its action row, and the
    /// manager is told nothing. The save that failed held both, so the row
    /// was not left for a later save to commit alone.
    ///
    /// Revert-check: staging the row after `save` in
    /// `MessageActions.performArchive` leaves the failed save without it;
    /// ignoring `save`'s result there tells the manager.
    ///
    /// HONEST SCOPE: the action's context is dropped when it returns, so the
    /// `rollback()` after the failed save cannot be told apart from leaving
    /// it out; what is pinned is that nothing was committed or announced.
    func testArchiveMessage_failedSave_leavesNeitherTheChangeNorItsActionRow() async throws {
        let fixture = try makeInboxConversation(inboxDates: [10], idPrefix: "failed-save-archive")
        let message = fixture.inboxMessages[0]
        let failingStack = RecordingFailingSaveCoreDataStack(wrapping: messageActionsStack)
        let actions = MessageActions(
            coreDataStack: failingStack,
            pendingActionsManager: pendingActionsManager,
            rollupMutationSerializer: rollupMutationSerializer,
            syncRunCoordinator: syncRunCoordinator
        )

        await actions.archive(message: message)

        let attempts = failingStack.attempts
        XCTAssertEqual(attempts.count, 1)
        XCTAssertEqual(attempts.first?.insertedEntityNames, ["PendingAction"])
        XCTAssertEqual(attempts.first?.updatedObjectIDs.contains(message.objectID), true)

        let rows = try await storedPendingActions()
        XCTAssertTrue(rows.isEmpty)
        let stored = try await storedMessageState(of: message.objectID)
        XCTAssertTrue(stored.labelIDs.contains("INBOX"))
        XCTAssertNil(stored.localModifiedAt)
        let queued = await pendingActionsManager.queuedSingleActions
        XCTAssertTrue(queued.isEmpty)
    }

    /// As the single-message case, for a conversation-wide action.
    ///
    /// Revert-check: staging the row after `save` in
    /// `MessageActions.applyConversationWideMutation` leaves the failed save
    /// without it.
    ///
    /// HONEST SCOPE: as above, the rollback itself is not observable.
    func testArchiveConversation_failedSave_leavesNeitherTheChangeNorItsActionRow() async throws {
        let fixture = try makeInboxConversation(inboxDates: [10, 20], idPrefix: "failed-save-conversation")
        let failingStack = RecordingFailingSaveCoreDataStack(wrapping: messageActionsStack)
        let actions = MessageActions(
            coreDataStack: failingStack,
            pendingActionsManager: pendingActionsManager,
            rollupMutationSerializer: rollupMutationSerializer,
            syncRunCoordinator: syncRunCoordinator
        )

        await actions.archiveConversation(conversation: fixture.conversation)

        let attempts = failingStack.attempts
        XCTAssertEqual(attempts.count, 1)
        XCTAssertEqual(attempts.first?.insertedEntityNames, ["PendingAction"])
        XCTAssertEqual(attempts.first?.updatedObjectIDs.contains(fixture.conversation.objectID), true)

        let rows = try await storedPendingActions()
        XCTAssertTrue(rows.isEmpty)
        for message in fixture.inboxMessages {
            let stored = try await storedMessageState(of: message.objectID)
            XCTAssertTrue(stored.labelIDs.contains("INBOX"))
            XCTAssertNil(stored.localModifiedAt)
        }
        let queued = await pendingActionsManager.queuedConversationActions
        XCTAssertTrue(queued.isEmpty)
    }

    /// Once Gmail has the archive, the real manager's processor clears every
    /// marker the row covers. `clearLocalModifications` clears only markers
    /// no later than the row's `createdAt`, so a row dated before its markers
    /// would leave the conversation's messages shielded from sync for 30
    /// minutes after Gmail had the change. The row is dated with the markers.
    ///
    /// Revert-check: dating the row a second before the markers in
    /// `MessageActions.applyConversationWideMutation` leaves every marker set;
    /// not scheduling processing in
    /// `PendingActionsManager.queueConversationAction(_:within:)` leaves the
    /// action unexecuted, its row pending and every marker set.
    func testArchiveConversation_actionCompletes_clearsEveryMarkerItCovers() async throws {
        let fixture = try makeInboxConversation(inboxDates: [10, 20], idPrefix: "markers-cleared")
        let executor = MockActionExecutor()
        let manager = PendingActionsManager(
            coreDataStack: CoreDataStack(persistentContainerForTesting: coreDataStack.persistentContainer),
            actionExecutor: executor,
            networkMonitor: ConnectedNetworkMonitorStub(),
            syncRunCoordinator: syncRunCoordinator,
            oneShotRepairDefaults: try makeIsolatedDefaults()
        )
        let actions = MessageActions(
            coreDataStack: messageActionsStack,
            pendingActionsManager: manager,
            rollupMutationSerializer: rollupMutationSerializer,
            syncRunCoordinator: syncRunCoordinator
        )

        await actions.archiveConversation(conversation: fixture.conversation)
        await manager.waitUntilScheduledProcessingIsIdle()

        let executed = await executor.executedActions
        XCTAssertEqual(executed.map(\.type), [.archiveConversation])
        for message in fixture.inboxMessages + [fixture.otherMessage] {
            let stored = try await storedMessageState(of: message.objectID)
            XCTAssertFalse(stored.labelIDs.contains("INBOX"))
            XCTAssertNil(stored.localModifiedAt, "A completed action clears the markers it covers")
        }
        let rows = try await storedPendingActions()
        XCTAssertTrue(rows.isEmpty, "The completed row is cleaned up")
    }

    /// Every `PendingAction` row in the store, oldest first, read on a
    /// context of its own.
    private func storedPendingActions() async throws -> [StoredPendingAction] {
        let context = coreDataStack.newBackgroundContext()
        return try await context.perform {
            let request = PendingAction.fetchRequest()
            request.sortDescriptors = [NSSortDescriptor(key: "createdAt", ascending: true)]
            return try context.fetch(request).map { action in
                var payloadMessageIDs: [String] = []
                if let data = action.payload?.data(using: .utf8),
                   let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    payloadMessageIDs = payload["messageIds"] as? [String] ?? []
                }
                return StoredPendingAction(
                    actionType: action.actionType,
                    messageId: action.messageId,
                    conversationId: action.conversationId,
                    payloadMessageIDs: payloadMessageIDs,
                    status: action.status,
                    createdAt: action.createdAt
                )
            }
        }
    }

    private func storedMessageState(of objectID: NSManagedObjectID) async throws -> StoredMessageState {
        let context = coreDataStack.newBackgroundContext()
        return try await context.perform {
            guard let message = try context.existingObject(with: objectID) as? Message else {
                throw MessageActionsTestError.messageMissing
            }
            return StoredMessageState(
                labelIDs: Set((message.labels ?? []).map(\.id)),
                isUnread: message.isUnread,
                localModifiedAt: message.localModifiedAt
            )
        }
    }

    private func makeIsolatedDefaults() throws -> UserDefaults {
        let suiteName = "MessageActionsTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suiteName)
        }
        return defaults
    }

    /// Saves the suite's main-queue context directly; the test body is
    /// already on its queue. `TestCoreDataStack.saveViewContext()` would save
    /// the stack's private-queue context instead (see the type comment).
    private func saveViewContext() throws {
        guard viewContext.hasChanges else { return }
        try viewContext.save()
    }

    /// Polls `condition` until it holds or `timeout` elapses. The condition is
    /// checked before the deadline on every pass, so a main-thread stall longer
    /// than the timeout cannot fail a condition that came true during the stall.
    private func waitUntil(
        timeout: TimeInterval = 2.0,
        pollIntervalNanoseconds: UInt64 = 20_000_000,
        file: StaticString = #filePath,
        line: UInt = #line,
        condition: @escaping @MainActor () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)

        while !condition() {
            guard Date() < deadline else {
                XCTFail("Timed out waiting for condition", file: file, line: line)
                return
            }
            try? await Task.sleep(nanoseconds: pollIntervalNanoseconds)
        }
    }

    /// Polls until `syncRunCoordinator` stops issuing account-work requests (a
    /// transition has begun quiescing) or `timeout` elapses. The coordinator is
    /// checked before the deadline on every pass, so a main-thread stall longer
    /// than the timeout cannot fail a transition that started during the stall.
    private func waitUntilAccountTransitionStarts(
        timeout: TimeInterval = 2.0,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let deadline = Date().addingTimeInterval(timeout)

        while await syncRunCoordinator.makeAccountWorkRequest() != nil {
            guard Date() < deadline else {
                XCTFail("Timed out waiting for account transition", file: file, line: line)
                return
            }
            await Task.yield()
        }
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

    // The `within:` witnesses are required (the protocol has no defaults); this
    // conformer gates them as it gates the acquiring overloads.
    func queueAction(
        _ action: PendingActionEnqueue.StagedMessageAction,
        within _: SyncRun
    ) async {
        await queueAction(type: action.type, messageId: action.messageId, payload: nil)
    }

    func queueConversationAction(
        type: PendingAction.ActionType,
        sourceConversationId: UUID,
        messageIds: [String]
    ) async {
        actionTypes.append(type)
    }

    func queueConversationAction(
        _ action: PendingActionEnqueue.StagedConversationAction,
        within _: SyncRun
    ) async {
        await queueConversationAction(
            type: action.type,
            sourceConversationId: action.sourceConversationId,
            messageIds: action.messageIds
        )
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
    case messageMissing
}

/// A pending action's row as the store has it.
private struct StoredPendingAction: Sendable {
    let actionType: String
    let messageId: String?
    let conversationId: UUID?
    let payloadMessageIDs: [String]
    let status: String
    let createdAt: Date
}

/// A message's labels, read state and marker as the store has them.
private struct StoredMessageState: Sendable {
    let labelIDs: Set<String>
    let isUnread: Bool
    let localModifiedAt: Date?
}

/// What one save committed, or what a save that was refused held.
private struct RecordedSave: Sendable {
    /// The entity name of every inserted object, sorted.
    let insertedEntityNames: [String]
    let updatedObjectIDs: Set<NSManagedObjectID>
}

/// Records what each save on one coordinator committed, from
/// `NSManagedObjectContextDidSave`, which is posted on the saving context's
/// queue, where the saved objects may be read.
///
/// `@unchecked Sendable`: `lock` guards `saves` and `observer`.
private final class SaveRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var saves: [RecordedSave] = []
    private var observer: NSObjectProtocol?

    init(coordinator: NSPersistentStoreCoordinator) {
        let coordinatorID = ObjectIdentifier(coordinator)
        let observer = NotificationCenter.default.addObserver(
            forName: .NSManagedObjectContextDidSave,
            object: nil,
            queue: nil
        ) { [weak self] notification in
            guard let context = notification.object as? NSManagedObjectContext,
                  let saved = context.persistentStoreCoordinator,
                  ObjectIdentifier(saved) == coordinatorID else {
                return
            }
            let inserted = notification.userInfo?[NSInsertedObjectsKey] as? Set<NSManagedObject> ?? []
            let updated = notification.userInfo?[NSUpdatedObjectsKey] as? Set<NSManagedObject> ?? []
            self?.append(RecordedSave(
                insertedEntityNames: inserted.compactMap { $0.entity.name }.sorted(),
                updatedObjectIDs: Set(updated.map(\.objectID))
            ))
        }
        lock.withLock { self.observer = observer }
    }

    /// Stops recording and returns every save recorded so far.
    func stop() -> [RecordedSave] {
        lock.withLock {
            if let observer {
                NotificationCenter.default.removeObserver(observer)
            }
            observer = nil
            return saves
        }
    }

    deinit {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    private func append(_ save: RecordedSave) {
        lock.withLock { saves.append(save) }
    }
}

/// Wraps a real test stack, records what each background save held, and
/// refuses it without saving, as a store that failed the save would.
///
/// `@unchecked Sendable`: `lock` guards `recordedAttempts`.
private final class RecordingFailingSaveCoreDataStack: MessageActionsCoreDataStacking, @unchecked Sendable {
    private let wrapped: MainQueueMessageActionsCoreDataStack
    private let lock = NSLock()
    private var recordedAttempts: [RecordedSave] = []

    init(wrapping wrapped: MainQueueMessageActionsCoreDataStack) {
        self.wrapped = wrapped
    }

    var viewContext: NSManagedObjectContext { wrapped.viewContext }

    /// Every refused save, in order.
    var attempts: [RecordedSave] {
        lock.withLock { recordedAttempts }
    }

    func newBackgroundContext() -> NSManagedObjectContext {
        wrapped.newBackgroundContext()
    }

    func saveIfNeeded(context: NSManagedObjectContext, caller: String) -> Bool {
        guard context !== wrapped.viewContext else {
            return wrapped.saveIfNeeded(context: context, caller: caller)
        }
        let attempt = context.performAndWait {
            RecordedSave(
                insertedEntityNames: context.insertedObjects.compactMap { $0.entity.name }.sorted(),
                updatedObjectIDs: Set(context.updatedObjects.map(\.objectID))
            )
        }
        lock.withLock { recordedAttempts.append(attempt) }
        return false
    }
}

private final class ConnectedNetworkMonitorStub: NetworkMonitorProtocol {
    var isConnected: Bool { true }
    var onConnectivityChange: ((Bool) -> Void)?
    func start() {}
    func stop() {}
}

/// Wraps a real test stack but reports every `saveIfNeeded` as failed, to exercise the
/// "don't sync remotely when the local save failed" gating in `MessageActions`.
private final class FailingSaveCoreDataStack: MessageActionsCoreDataStacking {
    private let wrapped: MainQueueMessageActionsCoreDataStack

    init(wrapping wrapped: MainQueueMessageActionsCoreDataStack) {
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

/// Wraps a real test stack and holds every background save until
/// `releaseSaves()`, so a test can act while an action is mid-save. The
/// save runs on the background context's queue, which is what waits.
///
/// `@unchecked Sendable`: `started` and `released` are guarded by `condition`.
private final class BlockingSaveCoreDataStack: MessageActionsCoreDataStacking, @unchecked Sendable {
    private let wrapped: MainQueueMessageActionsCoreDataStack
    private let condition = NSCondition()
    private var started = false
    private var released = false

    init(wrapping wrapped: MainQueueMessageActionsCoreDataStack) {
        self.wrapped = wrapped
    }

    var viewContext: NSManagedObjectContext { wrapped.viewContext }

    /// Whether a background save has been asked for.
    var saveHasStarted: Bool {
        condition.lock()
        defer { condition.unlock() }
        return started
    }

    func releaseSaves() {
        condition.lock()
        released = true
        condition.broadcast()
        condition.unlock()
    }

    func newBackgroundContext() -> NSManagedObjectContext {
        wrapped.newBackgroundContext()
    }

    func saveIfNeeded(context: NSManagedObjectContext, caller: String) -> Bool {
        if context !== wrapped.viewContext {
            condition.lock()
            started = true
            while !released {
                condition.wait()
            }
            condition.unlock()
        }
        return wrapped.saveIfNeeded(context: context, caller: caller)
    }
}

/// Wraps a real test stack and hands out background contexts whose fetches
/// of `Label` throw, while every other read and the saves go to the store.
private final class LabelFetchFailingCoreDataStack: MessageActionsCoreDataStacking, @unchecked Sendable {
    private let wrapped: MainQueueMessageActionsCoreDataStack
    private let coordinator: NSPersistentStoreCoordinator
    private let lock = NSLock()
    private var contexts: [EntityFetchFailingContext] = []

    init(wrapping wrapped: MainQueueMessageActionsCoreDataStack, coordinator: NSPersistentStoreCoordinator) {
        self.wrapped = wrapped
        self.coordinator = coordinator
    }

    var viewContext: NSManagedObjectContext { wrapped.viewContext }

    /// How many `Label` fetches the handed-out contexts rejected.
    var failedLabelFetches: Int {
        lock.lock()
        let made = contexts
        lock.unlock()
        return made.reduce(0) { $0 + $1.failedFetches }
    }

    func newBackgroundContext() -> NSManagedObjectContext {
        let context = EntityFetchFailingContext(failingEntityName: "Label", coordinator: coordinator)
        lock.lock()
        contexts.append(context)
        lock.unlock()
        return context
    }

    func saveIfNeeded(context: NSManagedObjectContext, caller: String) -> Bool {
        wrapped.saveIfNeeded(context: context, caller: caller)
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

    // The `within:` witnesses are required (the protocol has no defaults). They
    // record what `MessageActions` committed; the rows themselves are in the
    // test's store.
    func queueAction(_ action: PendingActionEnqueue.StagedMessageAction, within _: SyncRun) async {
        await queueAction(type: action.type, messageId: action.messageId, payload: nil)
    }

    func queueConversationAction(_ action: PendingActionEnqueue.StagedConversationAction, within _: SyncRun) async {
        await queueConversationAction(
            type: action.type,
            sourceConversationId: action.sourceConversationId,
            messageIds: action.messageIds
        )
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
