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
