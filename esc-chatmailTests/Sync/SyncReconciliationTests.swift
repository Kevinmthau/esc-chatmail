import XCTest
@testable import esc_chatmail

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

        let seedContext = stack.viewContext
        for index in 1...119 {
            MessageBuilder()
                .withId("message-\(index)")
                .withThreadId("thread-\(index)")
                .build(in: seedContext)
        }
        try stack.saveViewContext()

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
        mockAPI.listMessagesErrorsByPageToken["old-page-2"] = APIError.rateLimited
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
        mockAPI.listMessagesErrorsByPageToken["old-b-page-2"] = APIError.rateLimited
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

        let seedContext = stack.viewContext
        _ = LabelBuilder.inboxLabel(in: seedContext)
        let conversation = ConversationBuilder.simple(in: seedContext)
        MessageBuilder()
            .withId("message-needs-inbox")
            .withThreadId("thread-needs-inbox")
            .read()
            .inConversation(conversation)
            .build(in: seedContext)
        try stack.saveViewContext()

        let sut = SyncReconciliation(
            messageFetcher: MessageFetcher(apiClient: mockAPI)
        )
        let reconcileContext = stack.newBackgroundContext()

        await sut.reconcileLabelStates(
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

        let seedContext = stack.viewContext
        _ = LabelBuilder.inboxLabel(in: seedContext)
        let conversation = ConversationBuilder.simple(in: seedContext)
        MessageBuilder()
            .withId("message-needs-inbox")
            .withThreadId("thread-needs-inbox")
            .read()
            .inConversation(conversation)
            .build(in: seedContext)
        try stack.saveViewContext()

        let sut = SyncReconciliation(
            messageFetcher: MessageFetcher(apiClient: mockAPI)
        )
        let reconcileContext = stack.newBackgroundContext()

        let diagnostics = await sut.reconcileLabelStatesWithDiagnostics(
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
        XCTAssertEqual(diagnostics.labelMessagesChecked, 2)
        XCTAssertEqual(diagnostics.metadataFetchFailures, 1)
        XCTAssertEqual(diagnostics.driftFound, 1)
        XCTAssertEqual(diagnostics.driftRepaired, 1)
        XCTAssertTrue(reconciledState.isUnread)
        XCTAssertTrue(reconciledState.labelIds.contains("INBOX"))
    }

    private func seedMessages(_ range: ClosedRange<Int>) throws {
        let seedContext = stack.viewContext
        for index in range {
            MessageBuilder()
                .withId("message-\(index)")
                .withThreadId("thread-\(index)")
                .build(in: seedContext)
        }
        try stack.saveViewContext()
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
