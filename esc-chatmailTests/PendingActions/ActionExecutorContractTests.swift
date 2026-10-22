import XCTest
@testable import esc_chatmail

final class ActionExecutorContractTests: XCTestCase {

    func testGmailActionExecutor_markReadPayloadUsesBatchModify() async throws {
        let apiClient = MockGmailAPIClient()
        let executor = GmailActionExecutor(apiClientProvider: { apiClient })

        try await executor.execute(
            type: .markRead,
            messageId: nil,
            sourceConversationId: UUID(),
            payload: ["messageIds": ["msg-1", "msg-2"]]
        )

        XCTAssertEqual(apiClient.modifyMessageCallCount, 0)
        XCTAssertEqual(apiClient.batchModifyCallCount, 1)
        XCTAssertEqual(apiClient.batchModifyCalls.first?.ids, ["msg-1", "msg-2"])
        XCTAssertNil(apiClient.batchModifyCalls.first?.add)
        XCTAssertEqual(apiClient.batchModifyCalls.first?.remove, ["UNREAD"])
    }

    func testGmailActionExecutor_markReadPayloadChunksBatchModifyRequests() async throws {
        let apiClient = MockGmailAPIClient()
        let executor = GmailActionExecutor(apiClientProvider: { apiClient })
        let messageIds = (0..<2_001).map { "msg-\($0)" }

        try await executor.execute(
            type: .markRead,
            messageId: nil,
            sourceConversationId: UUID(),
            payload: ["messageIds": messageIds]
        )

        XCTAssertEqual(apiClient.modifyMessageCallCount, 0)
        XCTAssertEqual(apiClient.batchModifyCallCount, 3)
        XCTAssertEqual(apiClient.batchModifyCalls.map { $0.ids.count }, [1_000, 1_000, 1])
        XCTAssertEqual(apiClient.batchModifyCalls.flatMap(\.ids), messageIds)
        XCTAssertTrue(apiClient.batchModifyCalls.allSatisfy { $0.add == nil })
        XCTAssertTrue(apiClient.batchModifyCalls.allSatisfy { $0.remove == ["UNREAD"] })
    }

    /// Gmail rejects a batchModify naming more than 1,000 IDs, and the
    /// processor abandons the row on that 4xx after the local archive saved.
    ///
    /// Revert-check: calling `apiClient.batchModify` once with the whole
    /// payload in `GmailActionExecutor.execute`'s `.archiveConversation` arm
    /// (instead of the chunked `GmailActionExecutor.batchModify`) fails this.
    func testGmailActionExecutor_archiveConversationPayload_chunksBatchModifyRequests() async throws {
        let apiClient = MockGmailAPIClient()
        let executor = GmailActionExecutor(apiClientProvider: { apiClient })
        let messageIds = (0..<2_001).map { "msg-\($0)" }

        try await executor.execute(
            type: .archiveConversation,
            messageId: nil,
            sourceConversationId: UUID(),
            payload: ["messageIds": messageIds]
        )

        XCTAssertEqual(apiClient.modifyMessageCallCount, 0)
        XCTAssertEqual(apiClient.batchModifyCalls.map { $0.ids.count }, [1_000, 1_000, 1])
        XCTAssertEqual(apiClient.batchModifyCalls.flatMap(\.ids), messageIds, "Every ID is sent, none narrowed away")
        XCTAssertTrue(apiClient.batchModifyCalls.allSatisfy { $0.add == nil })
        XCTAssertTrue(apiClient.batchModifyCalls.allSatisfy { $0.remove == ["INBOX"] })
    }

    /// Revert-check: calling `apiClient.batchModify` once with the whole
    /// payload in `GmailActionExecutor.execute`'s `.reportSpam` arm fails this.
    func testGmailActionExecutor_reportSpamPayload_chunksBatchModifyRequests() async throws {
        let apiClient = MockGmailAPIClient()
        let executor = GmailActionExecutor(apiClientProvider: { apiClient })
        let messageIds = (0..<2_001).map { "msg-\($0)" }

        try await executor.execute(
            type: .reportSpam,
            messageId: nil,
            sourceConversationId: UUID(),
            payload: ["messageIds": messageIds]
        )

        XCTAssertEqual(apiClient.modifyMessageCallCount, 0)
        XCTAssertEqual(apiClient.batchModifyCalls.map { $0.ids.count }, [1_000, 1_000, 1])
        XCTAssertEqual(apiClient.batchModifyCalls.flatMap(\.ids), messageIds, "SPAM must reach every message")
        XCTAssertTrue(apiClient.batchModifyCalls.allSatisfy { $0.add == ["SPAM"] })
        XCTAssertTrue(apiClient.batchModifyCalls.allSatisfy { $0.remove == ["INBOX"] })
    }

    func testMockActionExecutor_batchActionAcceptsNilSourceConversationId() async throws {
        let executor = MockActionExecutor()
        let payload: [String: Any] = ["messageIds": ["msg-1", "msg-2"]]

        try await executor.execute(
            type: .archiveConversation,
            messageId: nil,
            sourceConversationId: nil,
            payload: payload
        )

        let executed = await executor.executedActions
        XCTAssertEqual(executed.count, 1)
        XCTAssertEqual(executed[0].type, .archiveConversation)
        XCTAssertNil(executed[0].messageId)
        XCTAssertNil(executed[0].sourceConversationId)
        XCTAssertEqual(executed[0].payload?["messageIds"] as? [String], ["msg-1", "msg-2"])
    }
}
