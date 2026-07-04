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

    // MARK: - Label reconciliation gating

    private let ttl: TimeInterval = 20 * 60
    private let forceInterval: TimeInterval = 3600
    private let now: TimeInterval = 1_750_000_000

    func testLabelReconciliation_runsWhenNeverReconciled() {
        XCTAssertFalse(IncrementalSyncOrchestrator.shouldSkipLabelReconciliation(
            noHistoryChanges: false, lastReconciliation: 0, now: now, ttl: ttl, forceInterval: forceInterval
        ))
        XCTAssertFalse(IncrementalSyncOrchestrator.shouldSkipLabelReconciliation(
            noHistoryChanges: true, lastReconciliation: 0, now: now, ttl: ttl, forceInterval: forceInterval
        ))
    }

    func testLabelReconciliation_withHistoryChanges_skipsInsideTTL() {
        XCTAssertTrue(IncrementalSyncOrchestrator.shouldSkipLabelReconciliation(
            noHistoryChanges: false, lastReconciliation: now - ttl + 1, now: now, ttl: ttl, forceInterval: forceInterval
        ))
    }

    func testLabelReconciliation_withHistoryChanges_runsOnceTTLLapses() {
        XCTAssertFalse(IncrementalSyncOrchestrator.shouldSkipLabelReconciliation(
            noHistoryChanges: false, lastReconciliation: now - ttl, now: now, ttl: ttl, forceInterval: forceInterval
        ))
    }

    func testLabelReconciliation_quietSync_skipsInsideForceInterval() {
        // Between the TTL and the hourly force interval, a quiet sync still skips:
        // the force timer exists for drift, not for every sync.
        XCTAssertTrue(IncrementalSyncOrchestrator.shouldSkipLabelReconciliation(
            noHistoryChanges: true, lastReconciliation: now - ttl - 60, now: now, ttl: ttl, forceInterval: forceInterval
        ))
    }

    func testLabelReconciliation_quietSync_runsOnceForceIntervalLapses() {
        XCTAssertFalse(IncrementalSyncOrchestrator.shouldSkipLabelReconciliation(
            noHistoryChanges: true, lastReconciliation: now - forceInterval, now: now, ttl: ttl, forceInterval: forceInterval
        ))
    }
}
