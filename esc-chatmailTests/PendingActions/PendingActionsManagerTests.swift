import XCTest
import CoreData
@testable import esc_chatmail

/// Tests for PendingActionsManager using in-memory Core Data stack.
///
/// Note: Full integration tests with PendingActionsManager require CoreDataStackProtocol
/// to be introduced. These tests focus on:
/// - Test infrastructure validation
/// - Core Data entity operations with builders
/// - Query logic validation
final class PendingActionsManagerTests: XCTestCase {

    var testStack: TestCoreDataStack!
    var context: NSManagedObjectContext!

    override func setUp() {
        super.setUp()
        testStack = TestCoreDataStack()
        context = testStack.viewContext
    }

    override func tearDown() {
        context = nil
        testStack = nil
        super.tearDown()
    }

    // MARK: - Test Infrastructure Tests

    func testTestCoreDataStack_createsValidContext() {
        XCTAssertNotNil(testStack.viewContext)
        XCTAssertNotNil(testStack.newBackgroundContext())
    }

    func testTestCoreDataStack_canSaveEntities() throws {
        // Create a pending action
        _ = PendingActionBuilder()
            .markAsRead()
            .forMessage("test-123")
            .pending()
            .build(in: context)

        // Save
        try testStack.saveViewContext()

        // Verify it can be fetched
        let request = PendingAction.fetchRequest()
        let results = try context.fetch(request)

        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.messageId, "test-123")
        XCTAssertEqual(results.first?.actionType, "markRead")
        XCTAssertEqual(results.first?.status, "pending")
    }

    func testTestCoreDataStack_isolatesBetweenInstances() throws {
        // Create entity in first stack
        let _ = PendingActionBuilder()
            .markAsRead()
            .forMessage("stack1-message")
            .build(in: context)
        try testStack.saveViewContext()

        // Create second stack
        let stack2 = TestCoreDataStack()

        // Verify second stack is empty
        let request = PendingAction.fetchRequest()
        let results = try stack2.viewContext.fetch(request)

        XCTAssertEqual(results.count, 0, "Second stack should be isolated and empty")
    }

    // MARK: - PendingAction Builder Tests

    func testPendingActionBuilder_setsAllProperties() throws {
        let conversationId = UUID()

        let action = PendingActionBuilder()
            .withId(UUID())
            .archive()
            .forConversation(conversationId)
            .failed()
            .withRetryCount(3)
            .createdMinutesAgo(5)
            .build(in: context)

        XCTAssertEqual(action.actionType, "archive")
        XCTAssertEqual(action.conversationId, conversationId)
        XCTAssertEqual(action.status, "failed")
        XCTAssertEqual(action.retryCount, 3)
        XCTAssertNotNil(action.createdAt)
    }

    func testPendingActionBuilder_createsWithPayload() throws {
        let payload = ["messageIds": ["msg1", "msg2", "msg3"]]

        let action = PendingActionBuilder()
            .withActionType("archiveConversation")
            .withPayload(payload)
            .build(in: context)

        XCTAssertNotNil(action.payload)

        // Verify payload can be decoded
        if let payloadData = action.payload?.data(using: .utf8),
           let decoded = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any],
           let messageIds = decoded["messageIds"] as? [String] {
            XCTAssertEqual(messageIds, ["msg1", "msg2", "msg3"])
        } else {
            XCTFail("Failed to decode payload")
        }
    }

    func testPendingActionBuilder_conveniences() throws {
        let simple = PendingActionBuilder.simple(in: context)
        XCTAssertEqual(simple.actionType, "markRead")
        XCTAssertEqual(simple.status, "pending")

        let failed = PendingActionBuilder.failedAction(in: context)
        XCTAssertEqual(failed.status, "failed")
        XCTAssertEqual(failed.retryCount, 1)
    }

    // MARK: - Message Builder Tests

    func testMessageBuilder_setsAllProperties() throws {
        let message = MessageBuilder()
            .withId("msg-123")
            .withThreadId("thread-456")
            .withSubject("Test Subject")
            .withSender(email: "sender@example.com", name: "John Doe")
            .withSnippet("This is a snippet...")
            .withBody("Full body text")
            .unread()
            .fromMe()
            .asNewsletter()
            .withAttachments()
            .build(in: context)

        XCTAssertEqual(message.id, "msg-123")
        XCTAssertEqual(message.gmThreadId, "thread-456")
        XCTAssertEqual(message.subject, "Test Subject")
        XCTAssertEqual(message.senderEmail, "sender@example.com")
        XCTAssertEqual(message.senderName, "John Doe")
        XCTAssertEqual(message.snippet, "This is a snippet...")
        XCTAssertEqual(message.bodyText, "Full body text")
        XCTAssertTrue(message.isUnread)
        XCTAssertTrue(message.isFromMe)
        XCTAssertTrue(message.isNewsletter)
        XCTAssertTrue(message.hasAttachments)
    }

    func testMessageBuilder_dateHelpers() throws {
        let message = MessageBuilder()
            .daysAgo(7)
            .build(in: context)

        let sevenDaysAgo = Calendar.current.date(byAdding: .day, value: -7, to: Date())!
        let difference = abs(message.internalDate.timeIntervalSince(sevenDaysAgo))

        XCTAssertLessThan(difference, 60, "Date should be approximately 7 days ago")
    }

    // MARK: - Conversation Builder Tests

    func testConversationBuilder_setsAllProperties() throws {
        let conversation = ConversationBuilder()
            .withDisplayName("Test Group")
            .withParticipantHash("abc123")
            .withSnippet("Latest message preview")
            .visible()
            .setPinned()
            .setMuted()
            .withUnreadCount(5)
            .recentlyActive()
            .build(in: context)

        XCTAssertEqual(conversation.displayName, "Test Group")
        XCTAssertEqual(conversation.participantHash, "abc123")
        XCTAssertEqual(conversation.snippet, "Latest message preview")
        XCTAssertNil(conversation.archivedAt)
        XCTAssertTrue(conversation.pinned)
        XCTAssertTrue(conversation.muted)
        XCTAssertEqual(conversation.inboxUnreadCount, 5)
        XCTAssertNotNil(conversation.lastMessageDate)
    }

    func testConversationBuilder_archivedState() throws {
        let archived = ConversationBuilder()
            .archived()
            .build(in: context)

        XCTAssertNotNil(archived.archivedAt)
    }

    // MARK: - Query Pattern Tests

    func testFetchPendingActions_filtersByStatus() throws {
        // Create actions with different statuses
        let _ = PendingActionBuilder()
            .pending()
            .forMessage("msg-1")
            .build(in: context)

        let _ = PendingActionBuilder()
            .failed()
            .forMessage("msg-2")
            .build(in: context)

        let _ = PendingActionBuilder()
            .completed()
            .forMessage("msg-3")
            .build(in: context)

        try testStack.saveViewContext()

        // Fetch pending or failed (like PendingActionsManager does)
        let request = PendingAction.fetchRequest()
        request.predicate = NSPredicate(
            format: "status == %@ OR status == %@",
            "pending", "failed"
        )

        let results = try context.fetch(request)

        XCTAssertEqual(results.count, 2)
        XCTAssertTrue(results.allSatisfy { $0.status == "pending" || $0.status == "failed" })
    }

    func testFetchPendingActions_filtersRetryCount() throws {
        // Create action under retry limit
        let _ = PendingActionBuilder()
            .failed()
            .withRetryCount(2)
            .forMessage("msg-under")
            .build(in: context)

        // Create action at retry limit
        let _ = PendingActionBuilder()
            .failed()
            .withRetryCount(5)
            .forMessage("msg-at-limit")
            .build(in: context)

        // Create action over retry limit
        let _ = PendingActionBuilder()
            .failed()
            .withRetryCount(6)
            .forMessage("msg-over")
            .build(in: context)

        try testStack.saveViewContext()

        // Fetch with retry count filter (like PendingActionsManager with maxRetries = 5)
        let request = PendingAction.fetchRequest()
        request.predicate = NSPredicate(
            format: "(status == %@ OR (status == %@ AND retryCount < %d))",
            "pending", "failed", 5
        )

        let results = try context.fetch(request)

        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.messageId, "msg-under")
    }

    func testFetchPendingActions_sortsByCreatedAt() throws {
        // Create actions in non-chronological order
        let _ = PendingActionBuilder()
            .forMessage("msg-old")
            .createdMinutesAgo(60)
            .build(in: context)

        let _ = PendingActionBuilder()
            .forMessage("msg-new")
            .createdMinutesAgo(1)
            .build(in: context)

        let _ = PendingActionBuilder()
            .forMessage("msg-middle")
            .createdMinutesAgo(30)
            .build(in: context)

        try testStack.saveViewContext()

        // Fetch sorted by createdAt
        let request = PendingAction.fetchRequest()
        request.sortDescriptors = [NSSortDescriptor(key: "createdAt", ascending: true)]

        let results = try context.fetch(request)

        XCTAssertEqual(results.count, 3)
        XCTAssertEqual(results[0].messageId, "msg-old")
        XCTAssertEqual(results[1].messageId, "msg-middle")
        XCTAssertEqual(results[2].messageId, "msg-new")
    }

    func testFetchPendingAction_byMessageIdAndType() throws {
        let _ = PendingActionBuilder()
            .markAsRead()
            .forMessage("target-msg")
            .pending()
            .build(in: context)

        let _ = PendingActionBuilder()
            .archive()
            .forMessage("target-msg")
            .pending()
            .build(in: context)

        let _ = PendingActionBuilder()
            .markAsRead()
            .forMessage("other-msg")
            .pending()
            .build(in: context)

        try testStack.saveViewContext()

        // Fetch specific action by message ID and type
        let request = PendingAction.fetchRequest()
        request.predicate = NSPredicate(
            format: "messageId == %@ AND actionType == %@ AND (status == %@ OR status == %@)",
            "target-msg", "markRead", "pending", "processing"
        )
        request.fetchLimit = 1

        let results = try context.fetch(request)

        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.messageId, "target-msg")
        XCTAssertEqual(results.first?.actionType, "markRead")
    }

    // MARK: - Async Test Helper Tests

    func testAsyncTestHelper_waitsForCompletion() throws {
        var completed = false

        try waitForAsync {
            try await Task.sleep(nanoseconds: 100_000_000) // 0.1 seconds
            completed = true
        }

        XCTAssertTrue(completed)
    }

    func testBackgroundContext_isolatesChanges() throws {
        // Create in view context
        let _ = PendingActionBuilder()
            .forMessage("view-context-msg")
            .build(in: context)

        // Don't save

        // Create background context and check
        let bgContext = testStack.newBackgroundContext()
        var bgCount = 0

        bgContext.performAndWait {
            let request = PendingAction.fetchRequest()
            bgCount = (try? bgContext.count(for: request)) ?? 0
        }

        XCTAssertEqual(bgCount, 0, "Unsaved changes should not be visible in background context")

        // Now save
        try testStack.saveViewContext()

        // Check again
        bgContext.performAndWait {
            let request = PendingAction.fetchRequest()
            bgCount = (try? bgContext.count(for: request)) ?? 0
        }

        XCTAssertEqual(bgCount, 1, "Saved changes should be visible after save")
    }

    // MARK: - Account transition isolation

    func testQueueActionWaitsBehindSyncAndPersistsWhenAccountDoesNotTransition() async throws {
        let coordinator = SyncRunCoordinator()
        guard let blockingRun = await coordinator.beginRun(kind: .foregroundIncremental) else {
            return XCTFail("Expected foreground sync to own the boundary")
        }
        guard let request = await coordinator.makeAccountWorkRequest() else {
            return XCTFail("Expected an account-work request while sync is active")
        }
        let manager = PendingActionsManager(
            coreDataStack: CoreDataStack(persistentContainerForTesting: testStack.persistentContainer),
            networkMonitor: NeverConnectedNetworkMonitor(),
            syncRunCoordinator: coordinator
        )

        let enqueueTask = Task {
            await manager.queueAction(
                type: .markRead,
                messageId: "waits-for-sync",
                accountWorkRequest: request
            )
        }
        for _ in 0..<20 {
            await Task.yield()
        }
        XCTAssertEqual(try pendingActionCount(), 0)

        await coordinator.endRun(blockingRun)
        await enqueueTask.value

        XCTAssertEqual(try pendingActionCount(), 1)
    }

    func testQueueActionBlockedBehindSyncAbortsAfterAccountTransition() async throws {
        let coordinator = SyncRunCoordinator()
        guard let blockingRun = await coordinator.beginRun(kind: .foregroundIncremental) else {
            return XCTFail("Expected foreground sync to own the boundary")
        }
        guard let oldAccountRequest = await coordinator.makeAccountWorkRequest() else {
            return XCTFail("Expected an account-work request while sync is active")
        }
        let manager = PendingActionsManager(
            coreDataStack: CoreDataStack(persistentContainerForTesting: testStack.persistentContainer),
            networkMonitor: NeverConnectedNetworkMonitor(),
            syncRunCoordinator: coordinator
        )

        let enqueueTask = Task {
            await manager.queueAction(
                type: .archive,
                messageId: "old-account-message",
                accountWorkRequest: oldAccountRequest
            )
        }
        let transitionTask = Task {
            await coordinator.beginQuiescence()
        }

        var transitionStarted = false
        for _ in 0..<100 {
            if await coordinator.makeAccountWorkRequest() == nil {
                transitionStarted = true
                break
            }
            await Task.yield()
        }
        XCTAssertTrue(transitionStarted, "Expected account transition to close the boundary")

        await coordinator.endRun(blockingRun)
        await transitionTask.value
        await coordinator.endQuiescence()
        await enqueueTask.value

        XCTAssertEqual(
            try pendingActionCount(),
            0,
            "A request stamped for the old account must not write into the reset store"
        )
    }

    func testProcessingBlockedBehindSyncResumesAgainstCurrentStoreAfterAccountTransition() async throws {
        let coordinator = SyncRunCoordinator()
        let lifecycleProbe = PendingActionLifecycleProbe()
        guard let blockingRun = await coordinator.beginRun(kind: .foregroundIncremental) else {
            return XCTFail("Expected foreground sync to own the boundary")
        }
        let executor = RecordingActionExecutor()
        let manager = PendingActionsManager(
            coreDataStack: CoreDataStack(persistentContainerForTesting: testStack.persistentContainer),
            actionExecutor: executor,
            networkMonitor: AlwaysConnectedNetworkMonitor(),
            syncRunCoordinator: coordinator,
            lifecycleHooks: PendingActionLifecycleHooks(
                scheduledProcessingDidWaitForRun: {
                    await lifecycleProbe.recordScheduledProcessingWait()
                },
                scheduledProcessingWillCreateInitialContext: {
                    await lifecycleProbe.recordScheduledProcessingContextCreation()
                }
            )
        )
        _ = PendingActionBuilder()
            .markAsRead()
            .forMessage("old-account-action")
            .pending()
            .build(in: context)
        try testStack.saveViewContext()

        let processingTask = Task {
            await manager.processAllPendingActions()
        }
        // Observe this exact scheduled scanner waiting. Initialization recovery
        // uses a different acquisition path and cannot satisfy this probe.
        await lifecycleProbe.waitUntilScheduledProcessingWaits()

        let transitionTask = Task {
            await coordinator.beginQuiescence()
        }
        var transitionStarted = false
        for _ in 0..<100 {
            if await coordinator.makeAccountWorkRequest() == nil {
                transitionStarted = true
                break
            }
            await Task.yield()
        }
        XCTAssertTrue(transitionStarted, "Expected account transition to close the boundary")

        await coordinator.endRun(blockingRun)
        await transitionTask.value

        // Replace the account-scoped rows while teardown owns the boundary,
        // then advance the probe's store generation. The scanner hook sits
        // immediately before its first context creation, so observing the new
        // generation proves no scanner context/fetch crossed the old boundary.
        let staleActions = try context.fetch(PendingAction.fetchRequest())
        staleActions.forEach(context.delete)
        _ = PendingActionBuilder()
            .markAsRead()
            .forMessage("current-account-action")
            .pending()
            .build(in: context)
        try testStack.saveViewContext()
        await lifecycleProbe.replaceStoreGeneration()

        await coordinator.endQuiescence()
        await processingTask.value

        XCTAssertEqual(executor.executedMessageIds, ["current-account-action"])
        let contextCreationGenerations = await lifecycleProbe.contextCreationGenerations
        XCTAssertEqual(
            contextCreationGenerations,
            [.replacement],
            "The scheduled scanner must create its first context only after store replacement"
        )
    }

    func testPendingActionCountRequestedBeforeAccountTransitionDoesNotReadReplacementStore() async throws {
        let coordinator = SyncRunCoordinator()
        guard let blockingRun = await coordinator.beginRun(kind: .foregroundIncremental),
              let oldAccountRequest = await coordinator.makeAccountWorkRequest() else {
            return XCTFail("Expected a foreground run and account-work request")
        }
        let manager = PendingActionsManager(
            coreDataStack: CoreDataStack(persistentContainerForTesting: testStack.persistentContainer),
            networkMonitor: NeverConnectedNetworkMonitor(),
            syncRunCoordinator: coordinator
        )

        let countTask = Task {
            await manager.pendingActionCount(accountWorkRequest: oldAccountRequest)
        }
        await coordinator.waitUntilWorkIsWaiting()

        let transitionTask = Task { await coordinator.beginQuiescence() }
        await waitUntilAccountTransitionStarts(coordinator)
        await coordinator.endRun(blockingRun)
        await transitionTask.value

        _ = PendingActionBuilder()
            .markAsRead()
            .forMessage("replacement-account-action")
            .pending()
            .build(in: context)
        try testStack.saveViewContext()

        await coordinator.endQuiescence()

        let staleCount = await countTask.value

        XCTAssertEqual(
            staleCount,
            0,
            "A stale live query must not observe rows from the replacement account"
        )
    }

    func testCancelRequestedBeforeAccountTransitionDoesNotDeleteReplacementAction() async throws {
        let coordinator = SyncRunCoordinator()
        guard let blockingRun = await coordinator.beginRun(kind: .foregroundIncremental),
              let oldAccountRequest = await coordinator.makeAccountWorkRequest() else {
            return XCTFail("Expected a foreground run and account-work request")
        }
        let manager = PendingActionsManager(
            coreDataStack: CoreDataStack(persistentContainerForTesting: testStack.persistentContainer),
            networkMonitor: NeverConnectedNetworkMonitor(),
            syncRunCoordinator: coordinator
        )

        _ = PendingActionBuilder()
            .markAsRead()
            .forMessage("same-message-id")
            .pending()
            .build(in: context)
        try testStack.saveViewContext()

        let cancelTask = Task {
            await manager.cancelPendingAction(
                forMessageId: "same-message-id",
                type: .markRead,
                accountWorkRequest: oldAccountRequest
            )
        }
        await coordinator.waitUntilWorkIsWaiting()

        let transitionTask = Task { await coordinator.beginQuiescence() }
        await waitUntilAccountTransitionStarts(coordinator)
        await coordinator.endRun(blockingRun)
        await transitionTask.value

        let oldActions = try context.fetch(PendingAction.fetchRequest())
        oldActions.forEach(context.delete)
        _ = PendingActionBuilder()
            .markAsRead()
            .forMessage("same-message-id")
            .pending()
            .build(in: context)
        try testStack.saveViewContext()

        await coordinator.endQuiescence()
        await cancelTask.value

        let actions = try context.fetch(PendingAction.fetchRequest())
        XCTAssertEqual(actions.map(\.messageId), ["same-message-id"])
    }

    func testDismissAllRequestedBeforeAccountTransitionDoesNotDeleteReplacementAbandonedActions() async throws {
        let coordinator = SyncRunCoordinator()
        guard let blockingRun = await coordinator.beginRun(kind: .foregroundIncremental),
              let oldAccountRequest = await coordinator.makeAccountWorkRequest() else {
            return XCTFail("Expected a foreground run and account-work request")
        }
        let manager = PendingActionsManager(
            coreDataStack: CoreDataStack(persistentContainerForTesting: testStack.persistentContainer),
            networkMonitor: NeverConnectedNetworkMonitor(),
            syncRunCoordinator: coordinator
        )

        let dismissTask = Task {
            await manager.dismissAllAbandonedActions(accountWorkRequest: oldAccountRequest)
        }
        await coordinator.waitUntilWorkIsWaiting()

        let transitionTask = Task { await coordinator.beginQuiescence() }
        await waitUntilAccountTransitionStarts(coordinator)
        await coordinator.endRun(blockingRun)
        await transitionTask.value

        _ = PendingActionBuilder()
            .archive()
            .forMessage("replacement-abandoned-action")
            .withStatus("abandoned")
            .build(in: context)
        try testStack.saveViewContext()

        await coordinator.endQuiescence()
        await dismissTask.value

        let actions = try context.fetch(PendingAction.fetchRequest())
        XCTAssertEqual(actions.map(\.messageId), ["replacement-abandoned-action"])
        XCTAssertEqual(actions.map(\.status), ["abandoned"])
    }

    private func pendingActionCount() throws -> Int {
        context.refreshAllObjects()
        return try context.count(for: PendingAction.fetchRequest())
    }

    private func waitUntilAccountTransitionStarts(
        _ coordinator: SyncRunCoordinator,
        timeout: TimeInterval = 2.0,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let deadline = Date().addingTimeInterval(timeout)

        while Date() < deadline {
            if await coordinator.makeAccountWorkRequest() == nil {
                return
            }
            await Task.yield()
        }

        XCTFail("Timed out waiting for account transition", file: file, line: line)
    }

    // MARK: - Account-scoped API failures

    func testScheduledProcessing_authenticationErrorStopsRunWithoutVerdicts() async throws {
        try await assertAccountScopedFailureStopsRunWithoutVerdicts(
            APIError.authenticationError
        )
    }

    func testScheduledProcessing_credentialsRevokedStopsRunWithoutVerdicts() async throws {
        try await assertAccountScopedFailureStopsRunWithoutVerdicts(
            APIError.credentialsRevoked
        )
    }

    private func assertAccountScopedFailureStopsRunWithoutVerdicts(
        _ error: APIError,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let executor = AccountScopedFailureOnceActionExecutor(error: error)
        let manager = PendingActionsManager(
            coreDataStack: CoreDataStack(
                persistentContainerForTesting: testStack.persistentContainer
            ),
            actionExecutor: executor,
            networkMonitor: AlwaysConnectedNetworkMonitor(),
            syncRunCoordinator: SyncRunCoordinator()
        )

        _ = PendingActionBuilder()
            .markAsRead()
            .forMessage("existing-action")
            .pending()
            .withRetryCount(4)
            .createdMinutesAgo(1)
            .build(in: context)
        try testStack.saveViewContext()

        await manager.queueAction(type: .archive, messageId: "remaining-action")
        await manager.waitUntilScheduledProcessingIsIdle()

        XCTAssertEqual(
            executor.executedMessageIds,
            ["existing-action"],
            "An account-scoped failure must stop before processing the remaining queue",
            file: file,
            line: line
        )

        context.refreshAllObjects()
        let request = PendingAction.fetchRequest()
        request.sortDescriptors = [NSSortDescriptor(key: "createdAt", ascending: true)]
        let actions = try context.fetch(request)
        XCTAssertEqual(
            actions.map(\.status),
            ["pending", "pending"],
            "Authentication state is not a verdict on either user action",
            file: file,
            line: line
        )
        XCTAssertEqual(
            actions.map(\.retryCount),
            [4, 0],
            "Authentication failures must not consume retry budget",
            file: file,
            line: line
        )
    }

    /// Quota exhaustion is account-scoped: it must stop the processing run
    /// with the failing action requeued untouched, instead of abandoning it
    /// and burning every remaining action's retry budget on doomed requests.
    func testProcessAllPendingActions_quotaExhaustionStopsRunWithoutVerdicts() async throws {
        let executor = QuotaExhaustedActionExecutor()
        let retryRecorder = QuotaRetryScheduleRecorder()
        let manager = PendingActionsManager(
            coreDataStack: CoreDataStack(persistentContainerForTesting: testStack.persistentContainer),
            actionExecutor: executor,
            networkMonitor: AlwaysConnectedNetworkMonitor(),
            syncRunCoordinator: SyncRunCoordinator(),
            quotaRetrySleeper: { delay in
                await retryRecorder.recordAndCancel(delay: delay)
            }
        )

        _ = PendingActionBuilder().markAsRead().forMessage("m1").pending().createdMinutesAgo(2).build(in: context)
        _ = PendingActionBuilder().markAsRead().forMessage("m2").pending().createdMinutesAgo(1).build(in: context)
        try testStack.saveViewContext()

        await manager.processAllPendingActions()
        await retryRecorder.waitUntilScheduled()

        XCTAssertEqual(
            executor.executeCallCount, 1,
            "Quota exhaustion must stop the run - remaining actions would fail identically"
        )
        let scheduledDelays = await retryRecorder.scheduledDelays
        XCTAssertEqual(scheduledDelays, [15 * 60])

        context.refreshAllObjects()
        let request = PendingAction.fetchRequest()
        request.sortDescriptors = [NSSortDescriptor(key: "createdAt", ascending: true)]
        let actions = try context.fetch(request)
        XCTAssertEqual(actions.map(\.status), ["pending", "pending"], "Quota exhaustion is not a verdict on the actions")
        XCTAssertEqual(actions.map(\.retryCount), [0, 0], "Quota exhaustion must not burn retry budget toward abandonment")
    }

    func testScheduledProcessing_quotaExhaustionDoesNotHotLoop() async throws {
        let executor = QuotaExhaustedActionExecutor()
        let manager = PendingActionsManager(
            coreDataStack: CoreDataStack(persistentContainerForTesting: testStack.persistentContainer),
            actionExecutor: executor,
            networkMonitor: AlwaysConnectedNetworkMonitor(),
            syncRunCoordinator: SyncRunCoordinator()
        )

        await manager.queueAction(type: .markRead, messageId: "scheduled-quota-action")
        await manager.waitUntilScheduledProcessingIsIdle()

        XCTAssertEqual(
            executor.executeCallCount,
            1,
            "A quota-requeued row must not immediately reschedule itself"
        )
        context.refreshAllObjects()
        let action = try XCTUnwrap(context.fetch(PendingAction.fetchRequest()).first)
        XCTAssertEqual(action.status, "pending")
        XCTAssertEqual(action.retryCount, 0)
    }

    func testScheduledProcessing_quotaExhaustionRetriesAfterBackoff() async throws {
        let sleeper = ControlledQuotaRetrySleeper()
        let executor = QuotaOnceThenSuccessActionExecutor()
        let manager = PendingActionsManager(
            coreDataStack: CoreDataStack(persistentContainerForTesting: testStack.persistentContainer),
            actionExecutor: executor,
            networkMonitor: AlwaysConnectedNetworkMonitor(),
            syncRunCoordinator: SyncRunCoordinator(),
            quotaRetryBaseDelay: 120,
            quotaRetryMaximumDelay: 480,
            quotaRetrySleeper: { delay in
                await sleeper.sleep(for: delay)
            }
        )

        await manager.queueAction(type: .markRead, messageId: "quota-retry-action")
        await manager.waitUntilScheduledProcessingIsIdle()
        await sleeper.waitUntilScheduled()

        let delays = await sleeper.scheduledDelays
        let firstAttemptMessageIds = await executor.executedMessageIds
        XCTAssertEqual(delays, [120])
        XCTAssertEqual(firstAttemptMessageIds, ["quota-retry-action"])

        await sleeper.resume()

        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            let attemptCount = await executor.executedMessageIds.count
            if attemptCount >= 2 { break }
            await Task.yield()
        }
        await manager.waitUntilScheduledProcessingIsIdle()

        let finalMessageIds = await executor.executedMessageIds
        XCTAssertEqual(
            finalMessageIds,
            ["quota-retry-action", "quota-retry-action"]
        )
        context.refreshAllObjects()
        XCTAssertTrue(try context.fetch(PendingAction.fetchRequest()).isEmpty)
    }

    func testQuotaRetryDelay_usesExponentialBackoffWithCap() {
        XCTAssertEqual(
            PendingActionsManager.quotaRetryDelay(
                forAttempt: 0,
                baseDelay: 120,
                maximumDelay: 480
            ),
            120
        )
        XCTAssertEqual(
            PendingActionsManager.quotaRetryDelay(
                forAttempt: 1,
                baseDelay: 120,
                maximumDelay: 480
            ),
            240
        )
        XCTAssertEqual(
            PendingActionsManager.quotaRetryDelay(
                forAttempt: 8,
                baseDelay: 120,
                maximumDelay: 480
            ),
            480
        )
    }

    func testAccountTransitionResetsQuotaRetryBackoff() async throws {
        let executor = QuotaExhaustedActionExecutor()
        let retryRecorder = QuotaRetryScheduleRecorder()
        let manager = PendingActionsManager(
            coreDataStack: CoreDataStack(
                persistentContainerForTesting: testStack.persistentContainer
            ),
            actionExecutor: executor,
            networkMonitor: AlwaysConnectedNetworkMonitor(),
            syncRunCoordinator: SyncRunCoordinator(),
            quotaRetryBaseDelay: 120,
            quotaRetryMaximumDelay: 480,
            quotaRetrySleeper: { delay in
                await retryRecorder.recordAndCancel(delay: delay)
            }
        )

        _ = PendingActionBuilder()
            .markAsRead()
            .forMessage("account-scoped-quota")
            .pending()
            .build(in: context)
        try testStack.saveViewContext()

        await manager.processAllPendingActions()
        await retryRecorder.waitUntilScheduled(count: 1)
        await manager.resetQuotaRetryStateForAccountTransition()
        await manager.processAllPendingActions()
        await retryRecorder.waitUntilScheduled(count: 2)

        let delays = await retryRecorder.scheduledDelays
        XCTAssertEqual(
            delays,
            [120, 120],
            "A new account must start at the base retry delay"
        )
    }

    func testScheduledProcessing_quotaExhaustionDefersConcurrentEnqueueUntilBackoff() async throws {
        let coordinator = SyncRunCoordinator()
        let lifecycleProbe = PendingActionLifecycleProbe()
        let sleeper = ControlledQuotaRetrySleeper()
        let executor = QuotaOnceThenSuccessActionExecutor()
        let manager = PendingActionsManager(
            coreDataStack: CoreDataStack(persistentContainerForTesting: testStack.persistentContainer),
            actionExecutor: executor,
            networkMonitor: AlwaysConnectedNetworkMonitor(),
            syncRunCoordinator: coordinator,
            lifecycleHooks: PendingActionLifecycleHooks(
                scheduledProcessingDidReleaseRun: {
                    await lifecycleProbe.pauseAfterFirstScheduledProcessingRun()
                }
            ),
            quotaRetryBaseDelay: 120,
            quotaRetryMaximumDelay: 480,
            quotaRetrySleeper: { delay in
                await sleeper.sleep(for: delay)
            }
        )

        await manager.queueAction(type: .markRead, messageId: "first-action")
        await lifecycleProbe.waitUntilFirstScheduledProcessingRunPauses()

        // The processing run has released the single-flight lease, but its
        // quota outcome has not cleared pendingProcessTask yet. This enqueue's
        // schedule request must be remembered without bypassing quota backoff.
        await manager.queueAction(type: .archive, messageId: "concurrent-action")
        await lifecycleProbe.resumeFirstScheduledProcessingRun()
        await manager.waitUntilScheduledProcessingIsIdle()
        await sleeper.waitUntilScheduled()

        let messageIdsBeforeBackoff = await executor.executedMessageIds
        let scheduledDelaysBeforeBackoff = await sleeper.scheduledDelays
        XCTAssertEqual(
            messageIdsBeforeBackoff,
            ["first-action"],
            "A concurrent enqueue must not trigger an immediate quota retry"
        )
        XCTAssertEqual(
            scheduledDelaysBeforeBackoff,
            [120],
            "Concurrent work must retain exactly one bounded quota retry"
        )

        context.refreshAllObjects()
        let pendingBeforeBackoff = try context.fetch(PendingAction.fetchRequest())
        XCTAssertEqual(pendingBeforeBackoff.count, 2)
        XCTAssertTrue(pendingBeforeBackoff.allSatisfy { $0.status == "pending" })
        XCTAssertTrue(pendingBeforeBackoff.allSatisfy { $0.retryCount == 0 })

        await sleeper.resume()

        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            let attemptCount = await executor.executedMessageIds.count
            if attemptCount >= 3 { break }
            await Task.yield()
        }
        await manager.waitUntilScheduledProcessingIsIdle()

        let finalMessageIds = await executor.executedMessageIds
        let finalScheduledDelays = await sleeper.scheduledDelays
        XCTAssertEqual(
            finalMessageIds,
            ["first-action", "first-action", "concurrent-action"]
        )
        XCTAssertEqual(finalScheduledDelays, [120])
        context.refreshAllObjects()
        XCTAssertTrue(try context.fetch(PendingAction.fetchRequest()).isEmpty)
    }

    func testScheduledProcessing_quotaExhaustionOfflineReconnectStillWaitsForBackoff() async throws {
        let networkMonitor = ControllableNetworkMonitor(isConnected: true)
        let sleeper = ControlledQuotaRetrySleeper()
        let executor = QuotaOnceThenSuccessActionExecutor()
        let manager = PendingActionsManager(
            coreDataStack: CoreDataStack(persistentContainerForTesting: testStack.persistentContainer),
            actionExecutor: executor,
            networkMonitor: networkMonitor,
            syncRunCoordinator: SyncRunCoordinator(),
            lifecycleHooks: PendingActionLifecycleHooks(
                scheduledProcessingDidReleaseRun: {
                    if await executor.executedMessageIds.count == 1 {
                        networkMonitor.setConnected(false)
                    }
                }
            ),
            quotaRetryBaseDelay: 120,
            quotaRetryMaximumDelay: 480,
            quotaRetrySleeper: { delay in
                await sleeper.sleep(for: delay)
            }
        )

        await manager.queueAction(type: .markRead, messageId: "offline-quota-action")
        await manager.waitUntilScheduledProcessingIsIdle()
        await sleeper.waitUntilScheduled()

        let attemptsBeforeReconnect = await executor.executedMessageIds
        let delaysBeforeReconnect = await sleeper.scheduledDelays
        XCTAssertFalse(networkMonitor.isConnected)
        XCTAssertEqual(attemptsBeforeReconnect, ["offline-quota-action"])
        XCTAssertEqual(delaysBeforeReconnect, [120])

        networkMonitor.setConnected(true)
        // Drain an explicit request too, proving both the reconnect callback
        // and a concurrent caller remain behind the same quota timer.
        await manager.processAllPendingActions()

        let attemptsAfterReconnect = await executor.executedMessageIds
        let delaysAfterReconnect = await sleeper.scheduledDelays
        XCTAssertEqual(
            attemptsAfterReconnect,
            ["offline-quota-action"],
            "Reconnect before quota expiry must not execute immediately"
        )
        XCTAssertEqual(
            delaysAfterReconnect,
            [120],
            "Reconnect must preserve exactly one quota retry"
        )

        await sleeper.resume()

        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            let attemptCount = await executor.executedMessageIds.count
            if attemptCount >= 2 { break }
            await Task.yield()
        }
        await manager.waitUntilScheduledProcessingIsIdle()

        let finalAttempts = await executor.executedMessageIds
        let finalDelays = await sleeper.scheduledDelays
        XCTAssertEqual(
            finalAttempts,
            ["offline-quota-action", "offline-quota-action"]
        )
        XCTAssertEqual(finalDelays, [120])
        context.refreshAllObjects()
        XCTAssertTrue(try context.fetch(PendingAction.fetchRequest()).isEmpty)
    }

    func testQuiescenceCancelsSuspendedScheduledExecutorThenProcessingResumes() async throws {
        let coordinator = SyncRunCoordinator()
        let executor = SuspendedCancellableActionExecutor()
        let manager = PendingActionsManager(
            coreDataStack: CoreDataStack(persistentContainerForTesting: testStack.persistentContainer),
            actionExecutor: executor,
            networkMonitor: AlwaysConnectedNetworkMonitor(),
            syncRunCoordinator: coordinator
        )

        await manager.queueAction(type: .archive, messageId: "cancel-during-teardown")
        await executor.waitUntilStarted()

        await coordinator.beginQuiescence()

        let wasCancelled = await executor.wasCancelled
        let activeRunKind = await coordinator.activeRunKind()
        let accountWorkRequest = await coordinator.makeAccountWorkRequest()
        XCTAssertTrue(wasCancelled)
        XCTAssertNil(activeRunKind)
        XCTAssertNil(accountWorkRequest)

        context.refreshAllObjects()
        let action = try XCTUnwrap(context.fetch(PendingAction.fetchRequest()).first)
        XCTAssertEqual(action.status, "pending")
        XCTAssertEqual(action.retryCount, 0)

        await coordinator.endQuiescence()
        await manager.waitUntilScheduledProcessingIsIdle()

        let executeCallCount = await executor.executeCallCount
        XCTAssertEqual(executeCallCount, 2)
        context.refreshAllObjects()
        XCTAssertTrue(try context.fetch(PendingAction.fetchRequest()).isEmpty)
    }

    func testRetryAbandonedActionReleasesMutationRunBeforeProcessing() async throws {
        let coordinator = SyncRunCoordinator()
        let lifecycleProbe = PendingActionLifecycleProbe()
        let executor = LeaseObservingActionExecutor(
            coordinator: coordinator,
            lifecycleProbe: lifecycleProbe
        )
        let manager = PendingActionsManager(
            coreDataStack: CoreDataStack(persistentContainerForTesting: testStack.persistentContainer),
            actionExecutor: executor,
            networkMonitor: AlwaysConnectedNetworkMonitor(),
            syncRunCoordinator: coordinator,
            lifecycleHooks: PendingActionLifecycleHooks(
                retryMutationDidResetAction: { syncRun in
                    await lifecycleProbe.recordRetryMutationRun(syncRun)
                }
            )
        )
        let abandonedAction = PendingActionBuilder()
            .markAsRead()
            .forMessage("retry-after-release")
            .withStatus("abandoned")
            .withRetryCount(5)
            .build(in: context)
        try testStack.saveViewContext()
        let objectID = abandonedAction.objectID

        await manager.retryAbandonedAction(objectID: objectID)

        let activeRunKind = await coordinator.activeRunKind()
        let executedMessageIds = await executor.executedMessageIds
        let mutationRunWasActiveAtExecutorEntry = await executor.mutationRunWasActiveAtEntry
        XCTAssertEqual(executedMessageIds, ["retry-after-release"])
        XCTAssertEqual(
            mutationRunWasActiveAtExecutorEntry,
            false,
            "The reset mutation lease must be released before executor entry"
        )
        XCTAssertNil(activeRunKind)
    }
}

// MARK: - Account-scoped failure test doubles

private final class AccountScopedFailureOnceActionExecutor: ActionExecutorProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private let error: APIError
    private var _executedMessageIds: [String] = []

    init(error: APIError) {
        self.error = error
    }

    var executedMessageIds: [String] {
        lock.withLock { _executedMessageIds }
    }

    func execute(
        type: PendingAction.ActionType,
        messageId: String?,
        sourceConversationId: UUID?,
        payload: [String: Any]?
    ) async throws {
        let shouldThrow = lock.withLock {
            if let messageId {
                _executedMessageIds.append(messageId)
            }
            return _executedMessageIds.count == 1
        }

        if shouldThrow {
            throw error
        }
    }
}

private final class QuotaExhaustedActionExecutor: ActionExecutorProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var _executeCallCount = 0

    var executeCallCount: Int {
        lock.withLock { _executeCallCount }
    }

    func execute(
        type: PendingAction.ActionType,
        messageId: String?,
        sourceConversationId: UUID?,
        payload: [String: Any]?
    ) async throws {
        lock.withLock { _executeCallCount += 1 }
        throw APIError.quotaExhausted("Daily Limit Exceeded")
    }
}

private actor QuotaOnceThenSuccessActionExecutor: ActionExecutorProtocol {
    private(set) var executedMessageIds: [String] = []

    func execute(
        type: PendingAction.ActionType,
        messageId: String?,
        sourceConversationId: UUID?,
        payload: [String: Any]?
    ) async throws {
        if let messageId {
            executedMessageIds.append(messageId)
        }
        if executedMessageIds.count == 1 {
            throw APIError.quotaExhausted("Daily Limit Exceeded")
        }
    }
}

private actor ControlledQuotaRetrySleeper {
    private(set) var scheduledDelays: [TimeInterval] = []
    private var didSchedule = false
    private var scheduleWaiters: [CheckedContinuation<Void, Never>] = []
    private var sleepContinuation: CheckedContinuation<Bool, Never>?

    func sleep(for delay: TimeInterval) async -> Bool {
        scheduledDelays.append(delay)
        didSchedule = true
        let waiters = scheduleWaiters
        scheduleWaiters.removeAll(keepingCapacity: false)
        waiters.forEach { $0.resume() }

        return await withCheckedContinuation { continuation in
            sleepContinuation = continuation
        }
    }

    func waitUntilScheduled() async {
        guard !didSchedule else { return }
        await withCheckedContinuation { continuation in
            scheduleWaiters.append(continuation)
        }
    }

    func resume() {
        sleepContinuation?.resume(returning: true)
        sleepContinuation = nil
    }
}

private actor QuotaRetryScheduleRecorder {
    private(set) var scheduledDelays: [TimeInterval] = []
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func recordAndCancel(delay: TimeInterval) -> Bool {
        scheduledDelays.append(delay)
        let currentWaiters = waiters
        waiters.removeAll(keepingCapacity: false)
        currentWaiters.forEach { $0.resume() }
        return false
    }

    func waitUntilScheduled(count: Int = 1) async {
        guard scheduledDelays.count < count else { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }
}

private final class RecordingActionExecutor: ActionExecutorProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var _executedMessageIds: [String] = []

    var executedMessageIds: [String] {
        lock.withLock { _executedMessageIds }
    }

    func execute(
        type: PendingAction.ActionType,
        messageId: String?,
        sourceConversationId: UUID?,
        payload: [String: Any]?
    ) async throws {
        if let messageId {
            lock.withLock { _executedMessageIds.append(messageId) }
        }
    }
}

private actor LeaseObservingActionExecutor: ActionExecutorProtocol {
    private let coordinator: SyncRunCoordinator
    private let lifecycleProbe: PendingActionLifecycleProbe

    private(set) var executedMessageIds: [String] = []
    private(set) var mutationRunWasActiveAtEntry: Bool?

    init(
        coordinator: SyncRunCoordinator,
        lifecycleProbe: PendingActionLifecycleProbe
    ) {
        self.coordinator = coordinator
        self.lifecycleProbe = lifecycleProbe
    }

    func execute(
        type: PendingAction.ActionType,
        messageId: String?,
        sourceConversationId: UUID?,
        payload: [String: Any]?
    ) async throws {
        guard let mutationRun = await lifecycleProbe.retryMutationRun else {
            return
        }

        mutationRunWasActiveAtEntry = await coordinator.isActiveRun(mutationRun)
        if let messageId {
            executedMessageIds.append(messageId)
        }
    }
}

private actor PendingActionLifecycleProbe {
    enum StoreGeneration: Equatable {
        case original
        case replacement
    }

    private var storeGeneration: StoreGeneration = .original
    private var didObserveScheduledProcessingWait = false
    private var scheduledProcessingWaiters: [CheckedContinuation<Void, Never>] = []
    private var didPauseAfterFirstScheduledProcessingRun = false
    private var firstScheduledProcessingRunPauseWaiters: [CheckedContinuation<Void, Never>] = []
    private var firstScheduledProcessingRunResumeContinuation: CheckedContinuation<Void, Never>?
    private(set) var contextCreationGenerations: [StoreGeneration] = []
    private(set) var retryMutationRun: SyncRun?

    func recordScheduledProcessingWait() {
        didObserveScheduledProcessingWait = true
        let waiters = scheduledProcessingWaiters
        scheduledProcessingWaiters.removeAll(keepingCapacity: false)
        waiters.forEach { $0.resume() }
    }

    func waitUntilScheduledProcessingWaits() async {
        guard !didObserveScheduledProcessingWait else { return }
        await withCheckedContinuation { continuation in
            scheduledProcessingWaiters.append(continuation)
        }
    }

    func replaceStoreGeneration() {
        storeGeneration = .replacement
    }

    func recordScheduledProcessingContextCreation() {
        contextCreationGenerations.append(storeGeneration)
    }

    func recordRetryMutationRun(_ syncRun: SyncRun) {
        retryMutationRun = syncRun
    }

    func pauseAfterFirstScheduledProcessingRun() async {
        guard !didPauseAfterFirstScheduledProcessingRun else { return }
        didPauseAfterFirstScheduledProcessingRun = true

        let waiters = firstScheduledProcessingRunPauseWaiters
        firstScheduledProcessingRunPauseWaiters.removeAll(keepingCapacity: false)
        waiters.forEach { $0.resume() }

        await withCheckedContinuation { continuation in
            firstScheduledProcessingRunResumeContinuation = continuation
        }
    }

    func waitUntilFirstScheduledProcessingRunPauses() async {
        guard !didPauseAfterFirstScheduledProcessingRun else { return }
        await withCheckedContinuation { continuation in
            firstScheduledProcessingRunPauseWaiters.append(continuation)
        }
    }

    func resumeFirstScheduledProcessingRun() {
        firstScheduledProcessingRunResumeContinuation?.resume()
        firstScheduledProcessingRunResumeContinuation = nil
    }
}

private actor SuspendedCancellableActionExecutor: ActionExecutorProtocol {
    private var didStart = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private(set) var wasCancelled = false
    private(set) var executeCallCount = 0

    func waitUntilStarted() async {
        guard !didStart else { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func execute(
        type: PendingAction.ActionType,
        messageId: String?,
        sourceConversationId: UUID?,
        payload: [String: Any]?
    ) async throws {
        executeCallCount += 1
        guard executeCallCount == 1 else { return }

        didStart = true
        let waiters = startWaiters
        startWaiters.removeAll(keepingCapacity: false)
        waiters.forEach { $0.resume() }

        do {
            try await Task.sleep(nanoseconds: 60_000_000_000)
        } catch is CancellationError {
            wasCancelled = true
            throw CancellationError()
        }
    }
}

private final class AlwaysConnectedNetworkMonitor: NetworkMonitorProtocol {
    var isConnected: Bool { true }
    var onConnectivityChange: ((Bool) -> Void)?
    func start() {}
    func stop() {}
}

private final class NeverConnectedNetworkMonitor: NetworkMonitorProtocol {
    var isConnected: Bool { false }
    var onConnectivityChange: ((Bool) -> Void)?
    func start() {}
    func stop() {}
}

private final class ControllableNetworkMonitor: NetworkMonitorProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var connected: Bool
    private var connectivityHandler: ((Bool) -> Void)?

    init(isConnected: Bool) {
        connected = isConnected
    }

    var isConnected: Bool {
        lock.withLock { connected }
    }

    var onConnectivityChange: ((Bool) -> Void)? {
        get { lock.withLock { connectivityHandler } }
        set { lock.withLock { connectivityHandler = newValue } }
    }

    func start() {}
    func stop() {}

    func setConnected(_ isConnected: Bool) {
        let handler = lock.withLock { () -> ((Bool) -> Void)? in
            guard connected != isConnected else { return nil }
            connected = isConnected
            return connectivityHandler
        }
        handler?(isConnected)
    }
}
