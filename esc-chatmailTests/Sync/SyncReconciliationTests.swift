import XCTest
@testable import esc_chatmail

/// Fixtures, saves, and assertions go through a main-queue context from
/// `TestCoreDataStack.makeMainQueueViewContext()`, never `stack.viewContext`,
/// which is private-queue. The test bodies use it directly, so `@MainActor` on
/// the class is what puts those accesses on-queue; see that helper for what the
/// private-queue shape races.
///
/// `SyncReconciliation` works on the background context each test hands it, so
/// this moves only the seed fixtures.
///
/// HONEST SCOPE: no test here can reproduce that race on demand. With
/// `-com.apple.CoreData.ConcurrencyDebug 1` the old shape traps and this shape
/// runs clean.
@MainActor
final class SyncReconciliationTests: XCTestCase {
    private var stack: TestCoreDataStack!

    override func setUpWithError() throws {
        try super.setUpWithError()
        stack = TestCoreDataStack()
        UserDefaults.standard.removeObject(forKey: SyncConfig.lastSuccessfulSyncTimeKey)
        UserDefaults.standard.removeObject(forKey: SyncConfig.missedMessageReconciliationCursorKey)
    }

    override func tearDownWithError() throws {
        UserDefaults.standard.removeObject(forKey: SyncConfig.lastSuccessfulSyncTimeKey)
        UserDefaults.standard.removeObject(forKey: SyncConfig.missedMessageReconciliationCursorKey)
        stack = nil
        try super.tearDownWithError()
    }

    func testCheckForMissedMessages_pagesThroughRecentResults() async throws {
        let mockAPI = MockGmailAPIClient()
        mockAPI.paginatedListMessagesResponses = [
            "__first_page__": MessagesListResponse(
                messages: (1...100).map { MessageListItem(id: "message-\($0)", threadId: "thread-\($0)") },
                nextPageToken: "page-2",
                resultSizeEstimate: 120
            ),
            "page-2": MessagesListResponse(
                messages: (101...120).map { MessageListItem(id: "message-\($0)", threadId: "thread-\($0)") },
                nextPageToken: nil,
                resultSizeEstimate: 120
            )
        ]

        let seedContext = stack.makeMainQueueViewContext()
        for index in 1...119 {
            MessageBuilder()
                .withId("message-\(index)")
                .withThreadId("thread-\(index)")
                .build(in: seedContext)
        }
        try seedContext.save()

        UserDefaults.standard.set(
            Date().addingTimeInterval(-(3 * 60 * 60)).timeIntervalSince1970,
            forKey: SyncConfig.lastSuccessfulSyncTimeKey
        )

        let sut = SyncReconciliation(
            messageFetcher: MessageFetcher(apiClient: mockAPI)
        )

        let missingIds = await sut.checkForMissedMessages(
            in: stack.newBackgroundContext(),
            installTimestamp: Date().addingTimeInterval(-(24 * 60 * 60)).timeIntervalSince1970
        )

        XCTAssertEqual(missingIds, ["message-120"])
        XCTAssertEqual(mockAPI.listMessagesCallCount, 2)
    }

    /// A last-sync time stamped while the device clock was two hours ahead of Gmail's:
    /// the missed-message check must list from Gmail's time, not from a point Gmail has
    /// not reached, where it found nothing (architecture review, gap-wall-clock-time#1).
    ///
    /// Revert-check: pass the device's `Date()` again as reconciliation's `now` in
    /// `SyncReconciliation.checkForMissedMessagesWithDiagnostics`.
    func testCheckForMissedMessages_stampAheadOfGmail_listsFromGmailsTime() async throws {
        let suiteName = "SyncReconciliationTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let mockAPI = MockGmailAPIClient()
        mockAPI.listMessagesResponse = MessagesListResponse(messages: [], nextPageToken: nil, resultSizeEstimate: 0)
        defaults.set(Date().timeIntervalSince1970, forKey: SyncConfig.lastSuccessfulSyncTimeKey)
        let sut = SyncReconciliation(
            messageFetcher: MessageFetcher(apiClient: mockAPI),
            failureTracker: SyncFailureTracker(defaults: defaults),
            defaults: defaults,
            // No lead: only `conservativeNow()` can move the floor, so the revert fails.
            serverTime: FakeServerTimeSource(serverOffsetFromDevice: -2 * 3600, reportsLead: false)
        )

        _ = await sut.checkForMissedMessagesWithDiagnostics(
            in: stack.newBackgroundContext(),
            installTimestamp: Date().addingTimeInterval(-(48 * 60 * 60)).timeIntervalSince1970
        )

        let query = try XCTUnwrap(mockAPI.listMessagesQueries.first ?? nil)
        let floor = try XCTUnwrap(
            query.range(of: "after:").flatMap { Int(query[$0.upperBound...].prefix { $0.isNumber }) },
            query
        )
        let gmailNow = Date().timeIntervalSince1970 - 2 * 3600
        XCTAssertLessThanOrEqual(TimeInterval(floor), gmailNow - SyncConfig.timestampBufferSeconds, query)
    }

    /// A last-sync time the device clock stamped while it was ahead, and that now has
    /// passed: the missed-message check lists from the lead earlier.
    ///
    /// Revert-check: pass no `deviceClockLead` from
    /// `SyncReconciliation.calculateReconciliationStartTime`.
    func testCheckForMissedMessages_passedStampWithTheClockAhead_listsTheLeadEarlier() async throws {
        let suiteName = "SyncReconciliationTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let mockAPI = MockGmailAPIClient()
        mockAPI.listMessagesResponse = MessagesListResponse(messages: [], nextPageToken: nil, resultSizeEstimate: 0)
        let stamp = TimeInterval(Int(Date().timeIntervalSince1970 - 6 * 3600))
        defaults.set(stamp, forKey: SyncConfig.lastSuccessfulSyncTimeKey)
        let sut = SyncReconciliation(
            messageFetcher: MessageFetcher(apiClient: mockAPI),
            failureTracker: SyncFailureTracker(defaults: defaults),
            defaults: defaults,
            serverTime: FakeServerTimeSource(serverOffsetFromDevice: -2 * 3600)
        )

        _ = await sut.checkForMissedMessagesWithDiagnostics(
            in: stack.newBackgroundContext(),
            installTimestamp: Date().addingTimeInterval(-(48 * 60 * 60)).timeIntervalSince1970
        )

        let query = try XCTUnwrap(mockAPI.listMessagesQueries.first ?? nil)
        let floor = try XCTUnwrap(
            query.range(of: "after:").flatMap { Int(query[$0.upperBound...].prefix { $0.isNumber }) },
            query
        )
        XCTAssertLessThanOrEqual(TimeInterval(floor), stamp - 2 * 3600 - SyncConfig.timestampBufferSeconds, query)
    }

    /// Label reconciliation's day is Gmail's day where the device clock is ahead.
    ///
    /// Revert-check: `Date()` in place of `serverTime.conservativeNow()` for `oneDayAgo` in
    /// `SyncReconciliation.reconcileLabelStatesWithDiagnostics`.
    func testReconcileLabelStates_deviceClockAhead_listsGmailsLastDay() async throws {
        let mockAPI = MockGmailAPIClient()
        mockAPI.listMessagesResponse = MessagesListResponse(messages: [], nextPageToken: nil, resultSizeEstimate: 0)
        let sut = SyncReconciliation(
            messageFetcher: MessageFetcher(apiClient: mockAPI),
            serverTime: FakeServerTimeSource(serverOffsetFromDevice: -2 * 3600)
        )

        _ = await sut.reconcileLabelStatesWithDiagnostics(
            in: stack.newBackgroundContext(),
            labelIds: [],
            modificationTransaction: nil
        )

        let query = try XCTUnwrap(mockAPI.listMessagesQueries.first ?? nil)
        let floor = try XCTUnwrap(
            query.range(of: "after:").flatMap { Int(query[$0.upperBound...].prefix { $0.isNumber }) },
            query
        )
        XCTAssertLessThanOrEqual(TimeInterval(floor), Date().timeIntervalSince1970 - 2 * 3600 - 86_400, query)
    }

    func testCheckForMissedMessagesWithDiagnosticsReportsCappedReconciliation() async throws {
        let mockAPI = MockGmailAPIClient()
        mockAPI.paginatedListMessagesResponses = [
            "__first_page__": MessagesListResponse(
                messages: (1...100).map { MessageListItem(id: "message-\($0)", threadId: "thread-\($0)") },
                nextPageToken: "page-2",
                resultSizeEstimate: 200
            )
        ]

        UserDefaults.standard.set(
            Date().timeIntervalSince1970,
            forKey: SyncConfig.lastSuccessfulSyncTimeKey
        )

        let sut = SyncReconciliation(
            messageFetcher: MessageFetcher(apiClient: mockAPI)
        )

        let result = await sut.checkForMissedMessagesWithDiagnostics(
            in: stack.newBackgroundContext(),
            installTimestamp: Date().addingTimeInterval(-(24 * 60 * 60)).timeIntervalSince1970
        )

        XCTAssertEqual(result.missingIds.count, 100)
        XCTAssertEqual(result.diagnostics.missedMessageCandidatesChecked, 100)
        XCTAssertEqual(result.diagnostics.missedMessagesFound, 100)
        XCTAssertTrue(result.diagnostics.cappedReconciliation)
        XCTAssertEqual(result.diagnostics.cappedAtMessageCount, 100)
        XCTAssertEqual(mockAPI.listMessagesCallCount, 1)
    }

    func testCheckForMissedMessagesWithDiagnosticsResumesCappedWindowsAcrossRuns() async throws {
        let mockAPI = MockGmailAPIClient()
        mockAPI.paginatedListMessagesResponses = [
            "__first_page__": MessagesListResponse(
                messages: (1...100).map { MessageListItem(id: "message-\($0)", threadId: "thread-\($0)") },
                nextPageToken: "page-2",
                resultSizeEstimate: 250
            ),
            "page-2": MessagesListResponse(
                messages: (101...200).map { MessageListItem(id: "message-\($0)", threadId: "thread-\($0)") },
                nextPageToken: "page-3",
                resultSizeEstimate: 250
            ),
            "page-3": MessagesListResponse(
                messages: (201...250).map { MessageListItem(id: "message-\($0)", threadId: "thread-\($0)") },
                nextPageToken: nil,
                resultSizeEstimate: 250
            )
        ]

        UserDefaults.standard.set(
            Date().timeIntervalSince1970,
            forKey: SyncConfig.lastSuccessfulSyncTimeKey
        )

        let sut = SyncReconciliation(
            messageFetcher: MessageFetcher(apiClient: mockAPI)
        )
        let installTimestamp = Date().addingTimeInterval(-(24 * 60 * 60)).timeIntervalSince1970

        let firstResult = await sut.checkForMissedMessagesWithDiagnostics(
            in: stack.newBackgroundContext(),
            installTimestamp: installTimestamp
        )

        XCTAssertEqual(firstResult.missingIds, (1...100).map { "message-\($0)" })
        XCTAssertTrue(firstResult.diagnostics.cappedReconciliation)
        XCTAssertFalse(firstResult.diagnostics.resumedMissedMessageWindow)
        XCTAssertEqual(mockAPI.listMessagesCallCount, 1)
        XCTAssertNil(mockAPI.listMessagesLastPageToken)

        try seedMessages(1...100)

        let secondResult = await sut.checkForMissedMessagesWithDiagnostics(
            in: stack.newBackgroundContext(),
            installTimestamp: installTimestamp
        )

        XCTAssertEqual(secondResult.missingIds, (101...200).map { "message-\($0)" })
        XCTAssertTrue(secondResult.diagnostics.cappedReconciliation)
        XCTAssertTrue(secondResult.diagnostics.resumedMissedMessageWindow)
        XCTAssertEqual(secondResult.diagnostics.missedMessageCandidatesChecked, 200)
        XCTAssertEqual(mockAPI.listMessagesCallCount, 3)
        XCTAssertEqual(mockAPI.listMessagesLastPageToken, "page-2")

        try seedMessages(101...200)

        let thirdResult = await sut.checkForMissedMessagesWithDiagnostics(
            in: stack.newBackgroundContext(),
            installTimestamp: installTimestamp
        )

        XCTAssertEqual(thirdResult.missingIds, (201...250).map { "message-\($0)" })
        XCTAssertFalse(thirdResult.diagnostics.cappedReconciliation)
        XCTAssertTrue(thirdResult.diagnostics.resumedMissedMessageWindow)
        XCTAssertEqual(thirdResult.diagnostics.missedMessageCandidatesChecked, 150)
        XCTAssertEqual(mockAPI.listMessagesCallCount, 5)
        XCTAssertEqual(mockAPI.listMessagesLastPageToken, "page-3")
    }

    func testCheckForMissedMessagesWithDiagnosticsIgnoresExpiredResumeCursor() async throws {
        let mockAPI = MockGmailAPIClient()
        mockAPI.paginatedListMessagesResponses = [
            "__first_page__": MessagesListResponse(
                messages: (1...100).map { MessageListItem(id: "message-\($0)", threadId: "thread-\($0)") },
                nextPageToken: "page-2",
                resultSizeEstimate: 150
            ),
            "page-2": MessagesListResponse(
                messages: (101...150).map { MessageListItem(id: "message-\($0)", threadId: "thread-\($0)") },
                nextPageToken: nil,
                resultSizeEstimate: 150
            )
        ]
        let staleStartedAt = Date()
            .addingTimeInterval(-SyncConfig.maxReconciliationWindow - 60)
            .timeIntervalSince1970
        let staleCursor = [
            "query": "after:0 -label:spam -label:drafts -label:trash",
            "pageToken": "page-2",
            "startedAt": staleStartedAt
        ] as [String: Any]
        let cursorData = try JSONSerialization.data(withJSONObject: staleCursor)
        UserDefaults.standard.set(cursorData, forKey: SyncConfig.missedMessageReconciliationCursorKey)

        UserDefaults.standard.set(
            Date().timeIntervalSince1970,
            forKey: SyncConfig.lastSuccessfulSyncTimeKey
        )

        let sut = SyncReconciliation(
            messageFetcher: MessageFetcher(apiClient: mockAPI)
        )

        let result = await sut.checkForMissedMessagesWithDiagnostics(
            in: stack.newBackgroundContext(),
            installTimestamp: Date().addingTimeInterval(-(24 * 60 * 60)).timeIntervalSince1970
        )

        XCTAssertEqual(result.missingIds, (1...100).map { "message-\($0)" })
        XCTAssertTrue(result.diagnostics.cappedReconciliation)
        XCTAssertFalse(result.diagnostics.resumedMissedMessageWindow)
        XCTAssertEqual(mockAPI.listMessagesCallCount, 1)
        XCTAssertNil(mockAPI.listMessagesLastPageToken)
    }

    func testCheckForMissedMessagesWithDiagnosticsPreservesCurrentOverflowWhileResumingOldCursor() async throws {
        let mockAPI = MockGmailAPIClient()
        mockAPI.paginatedListMessagesResponses = [
            "__first_page__": MessagesListResponse(
                messages: (1...100).map { MessageListItem(id: "current-\($0)", threadId: "current-thread-\($0)") },
                nextPageToken: "current-page-2",
                resultSizeEstimate: 150
            ),
            "old-page-2": MessagesListResponse(
                messages: (1...100).map { MessageListItem(id: "old-\($0)", threadId: "old-thread-\($0)") },
                nextPageToken: "old-page-3",
                resultSizeEstimate: 250
            )
        ]
        try setPersistedMissedMessageCursors([
            persistedCursor(query: "after:0 -label:spam -label:drafts -label:trash", pageToken: "old-page-2")
        ])

        UserDefaults.standard.set(
            Date().timeIntervalSince1970,
            forKey: SyncConfig.lastSuccessfulSyncTimeKey
        )

        let sut = SyncReconciliation(
            messageFetcher: MessageFetcher(apiClient: mockAPI)
        )

        let result = await sut.checkForMissedMessagesWithDiagnostics(
            in: stack.newBackgroundContext(),
            installTimestamp: Date().addingTimeInterval(-(24 * 60 * 60)).timeIntervalSince1970
        )

        XCTAssertEqual(result.missingIds.count, 200)
        XCTAssertTrue(result.diagnostics.cappedReconciliation)
        XCTAssertTrue(result.diagnostics.resumedMissedMessageWindow)
        XCTAssertEqual(mockAPI.listMessagesCallCount, 2)
        XCTAssertEqual(try persistedMissedMessageCursorTokens(), ["old-page-3", "current-page-2"])
    }

    func testCheckForMissedMessagesWithDiagnosticsKeepsResumeCursorOnTransientPageError() async throws {
        let mockAPI = MockGmailAPIClient()
        mockAPI.paginatedListMessagesResponses = [
            "__first_page__": MessagesListResponse(
                messages: [MessageListItem(id: "current-1", threadId: "current-thread-1")],
                nextPageToken: nil,
                resultSizeEstimate: 1
            )
        ]
        mockAPI.listMessagesErrorsByPageToken["old-page-2"] = APIError.rateLimited(retryAfter: nil)
        try setPersistedMissedMessageCursors([
            persistedCursor(query: "after:0 -label:spam -label:drafts -label:trash", pageToken: "old-page-2")
        ])

        UserDefaults.standard.set(
            Date().timeIntervalSince1970,
            forKey: SyncConfig.lastSuccessfulSyncTimeKey
        )

        let sut = SyncReconciliation(
            messageFetcher: MessageFetcher(apiClient: mockAPI)
        )

        let result = await sut.checkForMissedMessagesWithDiagnostics(
            in: stack.newBackgroundContext(),
            installTimestamp: Date().addingTimeInterval(-(24 * 60 * 60)).timeIntervalSince1970
        )

        XCTAssertTrue(result.missingIds.isEmpty)
        XCTAssertEqual(mockAPI.listMessagesCallCount, 2)
        XCTAssertEqual(try persistedMissedMessageCursorTokens(), ["old-page-2"])
    }

    func testCheckForMissedMessagesWithDiagnosticsPreservesPriorResumeCursorOnLaterTransientPageError() async throws {
        let mockAPI = MockGmailAPIClient()
        mockAPI.paginatedListMessagesResponses = [
            "__first_page__": MessagesListResponse(
                messages: [MessageListItem(id: "current-1", threadId: "current-thread-1")],
                nextPageToken: nil,
                resultSizeEstimate: 1
            ),
            "old-a-page-2": MessagesListResponse(
                messages: [MessageListItem(id: "old-a-1", threadId: "old-a-thread-1")],
                nextPageToken: nil,
                resultSizeEstimate: 1
            )
        ]
        mockAPI.listMessagesErrorsByPageToken["old-b-page-2"] = APIError.rateLimited(retryAfter: nil)
        try setPersistedMissedMessageCursors([
            persistedCursor(query: "after:0 -label:spam -label:drafts -label:trash", pageToken: "old-a-page-2"),
            persistedCursor(query: "after:1 -label:spam -label:drafts -label:trash", pageToken: "old-b-page-2")
        ])

        UserDefaults.standard.set(
            Date().timeIntervalSince1970,
            forKey: SyncConfig.lastSuccessfulSyncTimeKey
        )

        let sut = SyncReconciliation(
            messageFetcher: MessageFetcher(apiClient: mockAPI)
        )

        let result = await sut.checkForMissedMessagesWithDiagnostics(
            in: stack.newBackgroundContext(),
            installTimestamp: Date().addingTimeInterval(-(24 * 60 * 60)).timeIntervalSince1970
        )

        XCTAssertTrue(result.missingIds.isEmpty)
        XCTAssertEqual(mockAPI.listMessagesCallCount, 3)
        XCTAssertEqual(try persistedMissedMessageCursorTokens(), ["old-a-page-2", "old-b-page-2"])
    }

    func testReconcileLabelStates_fetchesMetadataThroughInjectedClient() async throws {
        let mockAPI = MockGmailAPIClient()
        mockAPI.setMessageList(["message-needs-inbox"])
        mockAPI.addMessage(
            GmailMessageBuilder()
                .withId("message-needs-inbox")
                .withLabels(["INBOX", "UNREAD"])
                .build()
        )

        let seedContext = stack.makeMainQueueViewContext()
        _ = LabelBuilder.inboxLabel(in: seedContext)
        let conversation = ConversationBuilder.simple(in: seedContext)
        MessageBuilder()
            .withId("message-needs-inbox")
            .withThreadId("thread-needs-inbox")
            .read()
            .inConversation(conversation)
            .build(in: seedContext)
        try seedContext.save()

        let sut = SyncReconciliation(
            messageFetcher: MessageFetcher(apiClient: mockAPI)
        )
        let reconcileContext = stack.newBackgroundContext()

        let result = await sut.reconcileLabelStatesWithDiagnostics(
            in: reconcileContext,
            labelIds: ["INBOX"],
            modificationTransaction: nil
        )

        let reconciledState = try await reconcileContext.perform {
            let request = Message.fetchRequest()
            request.predicate = NSPredicate(format: "id == %@", "message-needs-inbox")
            request.fetchLimit = 1

            let message = try XCTUnwrap(reconcileContext.fetch(request).first)
            let labelIds = Set((message.labels ?? []).map(\.id))
            return (isUnread: message.isUnread, labelIds: labelIds)
        }

        XCTAssertEqual(mockAPI.listMessagesCallCount, 1)
        XCTAssertEqual(mockAPI.getMessageCallCount, 1)
        XCTAssertEqual(mockAPI.getMessageCalledIds, ["message-needs-inbox"])
        XCTAssertEqual(mockAPI.getMessageCalledFormats, ["metadata"])
        XCTAssertEqual(result.outcome, .completed)
        XCTAssertTrue(reconciledState.isUnread)
        XCTAssertTrue(reconciledState.labelIds.contains("INBOX"))
    }

    func testReconcileLabelStatesWithDiagnosticsReportsMetadataFailuresAndDrift() async throws {
        let mockAPI = MockGmailAPIClient()
        mockAPI.setMessageList(["message-needs-inbox", "message-metadata-fails"])
        mockAPI.addMessage(
            GmailMessageBuilder()
                .withId("message-needs-inbox")
                .withLabels(["INBOX", "UNREAD"])
                .build()
        )
        mockAPI.getMessageErrors["message-metadata-fails"] = APIError.serverError(500)

        let seedContext = stack.makeMainQueueViewContext()
        _ = LabelBuilder.inboxLabel(in: seedContext)
        let conversation = ConversationBuilder.simple(in: seedContext)
        MessageBuilder()
            .withId("message-needs-inbox")
            .withThreadId("thread-needs-inbox")
            .read()
            .inConversation(conversation)
            .build(in: seedContext)
        try seedContext.save()

        let sut = SyncReconciliation(
            messageFetcher: MessageFetcher(apiClient: mockAPI)
        )
        let reconcileContext = stack.newBackgroundContext()

        let result = await sut.reconcileLabelStatesWithDiagnostics(
            in: reconcileContext,
            labelIds: ["INBOX"],
            modificationTransaction: nil
        )

        let reconciledState = try await reconcileContext.perform {
            let request = Message.fetchRequest()
            request.predicate = NSPredicate(format: "id == %@", "message-needs-inbox")
            request.fetchLimit = 1

            let message = try XCTUnwrap(reconcileContext.fetch(request).first)
            let labelIds = Set((message.labels ?? []).map(\.id))
            return (isUnread: message.isUnread, labelIds: labelIds)
        }

        XCTAssertEqual(mockAPI.getMessageCallCount, 2)
        XCTAssertEqual(result.outcome, .incomplete)
        XCTAssertEqual(result.diagnostics.labelMessagesChecked, 2)
        XCTAssertEqual(result.diagnostics.metadataFetchFailures, 1)
        XCTAssertEqual(result.diagnostics.driftFound, 1)
        XCTAssertEqual(result.diagnostics.driftRepaired, 1)
        XCTAssertTrue(reconciledState.isUnread)
        XCTAssertTrue(reconciledState.labelIds.contains("INBOX"))
    }

    // The review's pinning test (outbound-and-actions#4, background-energy#3):
    // a message archived and read locally two hours ago, its action still
    // queued, and Gmail still saying INBOX and UNREAD. The 30-minute marker
    // has lapsed; the live action keeps it as the user left it.
    // Revert-check: fails if `SyncReconciliation.processReconciliationMismatches`
    // stops skipping a message a live pending action names.
    func testReconcileLabelStates_liveQueuedActionKeepsALapsedLocalChange() async throws {
        let (state, outcome) = try await reconcileQueuedArchive(actionStatus: "failed")

        XCTAssertEqual(outcome, .completed)
        XCTAssertFalse(state.labelIds.contains("INBOX"), "The queued archive stays")
        XCTAssertFalse(state.isUnread, "The queued read stays")
    }

    func testReconcileLabelStates_abandonedActionNoLongerShieldsTheMessage() async throws {
        let (state, _) = try await reconcileQueuedArchive(actionStatus: "abandoned")

        XCTAssertTrue(state.labelIds.contains("INBOX"), "Gmail's state returns once the action gave up")
        XCTAssertTrue(state.isUnread)
    }

    // Revert-check: fails if `PendingActionTargets.liveTargetMessageIDs`
    // stops leaving out star and unstar: a queued star would stop INBOX and
    // UNREAD drift being repaired.
    func testReconcileLabelStates_queuedStarDoesNotBlockInboxRepair() async throws {
        let (state, _) = try await reconcileQueuedArchive(actionStatus: "pending", actionsAreStars: true)

        XCTAssertTrue(state.labelIds.contains("INBOX"))
        XCTAssertTrue(state.isUnread)
    }

    private func reconcileQueuedArchive(
        actionStatus: String,
        actionsAreStars: Bool = false
    ) async throws -> (state: (isUnread: Bool, labelIds: Set<String>), outcome: LabelReconciliationOutcome) {
        let mockAPI = MockGmailAPIClient()
        mockAPI.setMessageList(["queued-archive"])
        mockAPI.addMessage(
            GmailMessageBuilder().withId("queued-archive").withLabels(["INBOX", "UNREAD"]).build()
        )

        let seedContext = stack.makeMainQueueViewContext()
        _ = LabelBuilder.inboxLabel(in: seedContext)
        let conversation = ConversationBuilder.simple(in: seedContext)
        let message = MessageBuilder()
            .withId("queued-archive")
            .withThreadId("thread-queued-archive")
            .read()
            .inConversation(conversation)
            .build(in: seedContext)
        message.localModifiedAt = Date().addingTimeInterval(-2 * 60 * 60)
        _ = (actionsAreStars ? PendingActionBuilder().withActionType("star") : PendingActionBuilder().archive())
            .forMessage("queued-archive")
            .withStatus(actionStatus)
            .createdAt(Date().addingTimeInterval(-2 * 60 * 60))
            .build(in: seedContext)
        _ = (actionsAreStars ? PendingActionBuilder().withActionType("unstar") : PendingActionBuilder().markAsRead())
            .forMessage("queued-archive")
            .withStatus(actionStatus)
            .createdAt(Date().addingTimeInterval(-2 * 60 * 60))
            .build(in: seedContext)
        try seedContext.save()

        let sut = SyncReconciliation(messageFetcher: MessageFetcher(apiClient: mockAPI))
        let reconcileContext = stack.newBackgroundContext()
        let result = await sut.reconcileLabelStatesWithDiagnostics(
            in: reconcileContext,
            labelIds: ["INBOX"],
            modificationTransaction: nil
        )
        let state = try await reconcileContext.perform {
            let request = Message.fetchRequest()
            request.predicate = NSPredicate(format: "id == %@", "queued-archive")
            request.fetchLimit = 1
            let message = try XCTUnwrap(reconcileContext.fetch(request).first)
            return (isUnread: message.isUnread, labelIds: Set((message.labels ?? []).map(\.id)))
        }
        return (state, result.outcome)
    }

    func testReconcileLabelStatesWithDiagnosticsIsIncompleteWhenInboxLabelIsMissing() async throws {
        let mockAPI = MockGmailAPIClient()
        mockAPI.setMessageList(["message-needs-inbox"])
        mockAPI.addMessage(
            GmailMessageBuilder()
                .withId("message-needs-inbox")
                .withLabels(["INBOX"])
                .build()
        )

        let seedContext = stack.makeMainQueueViewContext()
        let conversation = ConversationBuilder.simple(in: seedContext)
        MessageBuilder()
            .withId("message-needs-inbox")
            .withThreadId("thread-needs-inbox")
            .inConversation(conversation)
            .build(in: seedContext)
        try seedContext.save()

        let sut = SyncReconciliation(messageFetcher: MessageFetcher(apiClient: mockAPI))
        let reconcileContext = stack.newBackgroundContext()
        let result = await sut.reconcileLabelStatesWithDiagnostics(
            in: reconcileContext,
            labelIds: [],
            modificationTransaction: nil
        )

        let hasInbox = try await reconcileContext.perform {
            let request = Message.fetchRequest()
            request.predicate = NSPredicate(format: "id == %@", "message-needs-inbox")
            request.fetchLimit = 1
            let message = try XCTUnwrap(reconcileContext.fetch(request).first)
            return (message.labels ?? []).contains { $0.id == "INBOX" }
        }

        XCTAssertEqual(result.outcome, .incomplete)
        XCTAssertEqual(result.diagnostics.driftFound, 1)
        XCTAssertEqual(result.diagnostics.driftRepaired, 0)
        XCTAssertEqual(result.diagnostics.skippedChecks, 1)
        XCTAssertFalse(hasInbox)
    }

    func testReconcileLabelStatesWithDiagnosticsCompletesAfterSuccessfulEmptyList() async {
        let mockAPI = MockGmailAPIClient()
        mockAPI.setMessageList([])
        let sut = SyncReconciliation(messageFetcher: MessageFetcher(apiClient: mockAPI))

        let result = await sut.reconcileLabelStatesWithDiagnostics(
            in: stack.newBackgroundContext(),
            labelIds: ["INBOX"],
            modificationTransaction: nil
        )

        XCTAssertEqual(result.outcome, .completed)
        XCTAssertEqual(result.diagnostics, SyncReconciliationDiagnostics())
    }

    func testReconcileLabelStatesWithDiagnosticsIsIncompleteWhenListRequestFails() async {
        let mockAPI = MockGmailAPIClient()
        mockAPI.listMessagesError = APIError.serverError(500)
        let sut = SyncReconciliation(messageFetcher: MessageFetcher(apiClient: mockAPI))

        let result = await sut.reconcileLabelStatesWithDiagnostics(
            in: stack.newBackgroundContext(),
            labelIds: ["INBOX"],
            modificationTransaction: nil
        )

        XCTAssertEqual(result.outcome, .incomplete)
        XCTAssertEqual(mockAPI.listMessagesCallCount, 1)
    }

    func testReconcileLabelStatesWithDiagnosticsIsIncompleteWhenAllMetadataRequestsFail() async {
        let mockAPI = MockGmailAPIClient()
        mockAPI.setMessageList(["message-1", "message-2"])
        mockAPI.getMessageErrors = [
            "message-1": APIError.serverError(500),
            "message-2": APIError.serverError(500)
        ]
        let sut = SyncReconciliation(messageFetcher: MessageFetcher(apiClient: mockAPI))

        let result = await sut.reconcileLabelStatesWithDiagnostics(
            in: stack.newBackgroundContext(),
            labelIds: ["INBOX"],
            modificationTransaction: nil
        )

        XCTAssertEqual(result.outcome, .incomplete)
        XCTAssertEqual(result.diagnostics.metadataFetchFailures, 2)
    }

    func testReconciliationPhaseReportsLabelsNotRequestedWhenSkipped() async throws {
        let mockAPI = MockGmailAPIClient()
        mockAPI.setMessageList([])
        let messageFetcher = MessageFetcher(apiClient: mockAPI)
        let phase = ReconciliationPhase(
            reconciliation: SyncReconciliation(messageFetcher: messageFetcher),
            messageFetcher: messageFetcher,
            messagePersister: MessagePersister()
        )
        let context = SyncPhaseContext(
            coreDataContext: stack.newBackgroundContext(),
            labelIds: [],
            myAliases: [],
            syncStartTime: Date(),
            progressHandler: { _, _ in },
            failureTracker: .shared
        )

        let result = try await phase.execute(
            input: ReconciliationInput(skipLabelReconciliation: true),
            context: context
        )

        XCTAssertEqual(result.labelOutcome, .notRequested)
        XCTAssertEqual(mockAPI.listMessagesCallCount, 1)
    }

    private func seedMessages(_ range: ClosedRange<Int>) throws {
        let seedContext = stack.makeMainQueueViewContext()
        for index in range {
            MessageBuilder()
                .withId("message-\(index)")
                .withThreadId("thread-\(index)")
                .build(in: seedContext)
        }
        try seedContext.save()
    }

    private func persistedCursor(query: String, pageToken: String) -> [String: Any] {
        [
            "query": query,
            "pageToken": pageToken,
            "startedAt": Date().timeIntervalSince1970
        ]
    }

    private func setPersistedMissedMessageCursors(_ cursors: [[String: Any]]) throws {
        let json: Any = cursors.count == 1 ? cursors[0] : cursors
        let data = try JSONSerialization.data(withJSONObject: json)
        UserDefaults.standard.set(data, forKey: SyncConfig.missedMessageReconciliationCursorKey)
    }

    private func persistedMissedMessageCursorTokens() throws -> [String] {
        guard let data = UserDefaults.standard.data(forKey: SyncConfig.missedMessageReconciliationCursorKey) else {
            return []
        }

        let json = try JSONSerialization.jsonObject(with: data)
        if let cursors = json as? [[String: Any]] {
            return cursors.compactMap { $0["pageToken"] as? String }
        }
        if let cursor = json as? [String: Any],
           let pageToken = cursor["pageToken"] as? String {
            return [pageToken]
        }
        return []
    }
}
