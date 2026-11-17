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
    /// Revert-check: ignoring the result of `saveIfNeeded` in
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
