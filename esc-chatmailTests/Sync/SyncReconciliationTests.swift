import XCTest
@testable import esc_chatmail

final class SyncReconciliationTests: XCTestCase {
    private var stack: TestCoreDataStack!

    override func setUpWithError() throws {
        try super.setUpWithError()
        stack = TestCoreDataStack()
        UserDefaults.standard.removeObject(forKey: SyncConfig.lastSuccessfulSyncTimeKey)
    }

    override func tearDownWithError() throws {
        UserDefaults.standard.removeObject(forKey: SyncConfig.lastSuccessfulSyncTimeKey)
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
}
