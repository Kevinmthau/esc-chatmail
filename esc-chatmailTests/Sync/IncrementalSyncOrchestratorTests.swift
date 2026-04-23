import XCTest
@testable import esc_chatmail

final class IncrementalSyncOrchestratorTests: XCTestCase {
    func testAllowsIntermediateContextSaves_allowsNonDestructiveHistory() {
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
            IncrementalSyncOrchestrator.allowsIntermediateContextSaves(for: [record])
        )
    }

    func testAllowsIntermediateContextSaves_defersWhenHistoryDeletesMessages() {
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
            IncrementalSyncOrchestrator.allowsIntermediateContextSaves(for: [record])
        )
    }

    func testAllowsIntermediateContextSaves_defersWhenMessagesAddedLabelsAreOmitted() {
        let record = HistoryRecord(
            id: "history-messages-added-unknown-labels",
            messages: nil,
            messagesAdded: [
                HistoryMessageAdded(
                    message: GmailMessage(
                        id: "message-1",
                        threadId: "thread-1",
                        labelIds: nil,
                        snippet: nil,
                        historyId: nil,
                        internalDate: nil,
                        payload: nil,
                        sizeEstimate: nil
                    )
                )
            ],
            messagesDeleted: nil,
            labelsAdded: nil,
            labelsRemoved: nil
        )

        XCTAssertFalse(
            IncrementalSyncOrchestrator.allowsIntermediateContextSaves(for: [record])
        )
    }

    func testAllowsIntermediateContextSaves_defersWhenHistoryAddsExcludedMailboxLabel() {
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
            IncrementalSyncOrchestrator.allowsIntermediateContextSaves(for: [record])
        )
    }
}
