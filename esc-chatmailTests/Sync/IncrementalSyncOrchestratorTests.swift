import XCTest
@testable import esc_chatmail

final class IncrementalSyncOrchestratorTests: XCTestCase {
    func testShouldFlushUIVisibleChanges_allowsNonDestructiveHistory() {
        let record = HistoryRecord(
            id: "history-safe",
            messages: nil,
            messagesAdded: nil,
            messagesDeleted: nil,
            labelsAdded: [
                HistoryLabelAdded(
                    message: MessageListItem(id: "message-1", threadId: nil),
                    labelIds: ["UNREAD"]
                )
            ],
            labelsRemoved: [
                HistoryLabelRemoved(
                    message: MessageListItem(id: "message-1", threadId: nil),
                    labelIds: ["INBOX"]
                )
            ]
        )

        XCTAssertTrue(
            IncrementalSyncOrchestrator.shouldFlushUIVisibleChanges(
                afterLabelProcessingFor: [record]
            )
        )
    }

    func testShouldFlushUIVisibleChanges_defersWhenHistoryDeletesMessages() {
        let record = HistoryRecord(
            id: "history-delete",
            messages: nil,
            messagesAdded: nil,
            messagesDeleted: [
                HistoryMessageDeleted(message: MessageListItem(id: "message-1", threadId: nil))
            ],
            labelsAdded: nil,
            labelsRemoved: nil
        )

        XCTAssertFalse(
            IncrementalSyncOrchestrator.shouldFlushUIVisibleChanges(
                afterLabelProcessingFor: [record]
            )
        )
    }

    func testShouldFlushUIVisibleChanges_defersWhenHistoryAddsExcludedMailboxLabel() {
        let record = HistoryRecord(
            id: "history-trash",
            messages: nil,
            messagesAdded: nil,
            messagesDeleted: nil,
            labelsAdded: [
                HistoryLabelAdded(
                    message: MessageListItem(id: "message-1", threadId: nil),
                    labelIds: ["TRASH"]
                )
            ],
            labelsRemoved: nil
        )

        XCTAssertFalse(
            IncrementalSyncOrchestrator.shouldFlushUIVisibleChanges(
                afterLabelProcessingFor: [record]
            )
        )
    }
}
