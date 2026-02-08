import XCTest
@testable import esc_chatmail

final class ActionExecutorContractTests: XCTestCase {

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
