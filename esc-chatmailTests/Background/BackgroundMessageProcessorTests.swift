import XCTest
@testable import esc_chatmail

final class BackgroundMessageProcessorTests: XCTestCase {
    func testBuildChangeSet_includesMessagesFromLabelChanges() {
        let record = HistoryRecord(
            id: "h1",
            messages: nil,
            messagesAdded: nil,
            messagesDeleted: nil,
            labelsAdded: [
                HistoryLabelAdded(
                    message: MessageListItem(id: "m-label-add", threadId: nil),
                    labelIds: ["UNREAD"]
                )
            ],
            labelsRemoved: [
                HistoryLabelRemoved(
                    message: MessageListItem(id: "m-label-remove", threadId: nil),
                    labelIds: ["INBOX"]
                )
            ]
        )

        let changeSet = BackgroundMessageProcessor.buildChangeSet(from: [record])

        XCTAssertEqual(
            changeSet.messageIdsToFetch,
            Set(["m-label-add", "m-label-remove"])
        )
        XCTAssertTrue(changeSet.messageIdsToDelete.isEmpty)
    }

    func testBuildChangeSet_skipsSpamMessagesAdded() {
        let spamMessage = GmailMessage(
            id: "m-spam",
            threadId: nil,
            labelIds: ["SPAM"],
            snippet: nil,
            historyId: nil,
            internalDate: nil,
            payload: nil,
            sizeEstimate: nil
        )
        let normalMessage = GmailMessage(
            id: "m-normal",
            threadId: nil,
            labelIds: ["INBOX"],
            snippet: nil,
            historyId: nil,
            internalDate: nil,
            payload: nil,
            sizeEstimate: nil
        )

        let record = HistoryRecord(
            id: "h2",
            messages: nil,
            messagesAdded: [
                HistoryMessageAdded(message: spamMessage),
                HistoryMessageAdded(message: normalMessage)
            ],
            messagesDeleted: nil,
            labelsAdded: nil,
            labelsRemoved: nil
        )

        let changeSet = BackgroundMessageProcessor.buildChangeSet(from: [record])

        XCTAssertEqual(changeSet.messageIdsToFetch, Set(["m-normal"]))
        XCTAssertFalse(changeSet.messageIdsToFetch.contains("m-spam"))
    }

    func testBuildChangeSet_deletionsTakePrecedenceOverFetches() {
        let addedMessage = GmailMessage(
            id: "m1",
            threadId: nil,
            labelIds: ["INBOX"],
            snippet: nil,
            historyId: nil,
            internalDate: nil,
            payload: nil,
            sizeEstimate: nil
        )

        let record = HistoryRecord(
            id: "h3",
            messages: nil,
            messagesAdded: [HistoryMessageAdded(message: addedMessage)],
            messagesDeleted: [HistoryMessageDeleted(message: MessageListItem(id: "m1", threadId: nil))],
            labelsAdded: [HistoryLabelAdded(message: MessageListItem(id: "m1", threadId: nil), labelIds: ["UNREAD"])],
            labelsRemoved: nil
        )

        let changeSet = BackgroundMessageProcessor.buildChangeSet(from: [record])

        XCTAssertEqual(changeSet.messageIdsToDelete, Set(["m1"]))
        XCTAssertFalse(changeSet.messageIdsToFetch.contains("m1"))
    }
}
