import XCTest
import CoreData
@testable import esc_chatmail

/// Fixtures, saves, and assertions go through a main-queue context from
/// `TestCoreDataStack.makeMainQueueViewContext()`, never
/// `testStack.viewContext`, which is private-queue. The test bodies use it
/// directly, so `@MainActor` on the class is what puts those accesses on-queue;
/// see that helper for what the private-queue shape races.
///
/// HONEST SCOPE: no test here can reproduce that race on demand. With
/// `-com.apple.CoreData.ConcurrencyDebug 1` the old shape traps and this shape
/// runs clean.
@MainActor
final class HistoryProcessorTests: XCTestCase {

    private var testStack: TestCoreDataStack!

    override func setUpWithError() throws {
        try super.setUpWithError()
        testStack = TestCoreDataStack()
    }

    override func tearDownWithError() throws {
        testStack = nil
        try super.tearDownWithError()
    }

    // MARK: - extractNewMessageIds (pure function)

    private func makeGmailMessage(id: String, labelIds: [String]? = nil) -> GmailMessage {
        GmailMessage(
            id: id,
            threadId: "thread-\(id)",
            labelIds: labelIds,
            snippet: nil,
            historyId: nil,
            internalDate: nil,
            payload: nil,
            sizeEstimate: nil
        )
    }

    private func makeHistoryRecord(
        id: String = "h1",
        messagesAdded: [HistoryMessageAdded]? = nil,
        messagesDeleted: [HistoryMessageDeleted]? = nil,
        labelsAdded: [HistoryLabelAdded]? = nil,
        labelsRemoved: [HistoryLabelRemoved]? = nil
    ) -> HistoryRecord {
        HistoryRecord(
            id: id,
            messages: nil,
            messagesAdded: messagesAdded,
            messagesDeleted: messagesDeleted,
            labelsAdded: labelsAdded,
            labelsRemoved: labelsRemoved
        )
    }

    func testExtractNewMessageIds_emptyRecords_returnsEmptySet() {
        let processor = HistoryProcessor(coreDataStack: .shared)
        let result = processor.extractNewMessageIds(from: [])
        XCTAssertTrue(result.isEmpty)
    }

    func testExtractNewMessageIds_recordsWithNoMessagesAdded_returnsEmptySet() {
        let processor = HistoryProcessor(coreDataStack: .shared)
        let records = [makeHistoryRecord(messagesAdded: nil)]
        XCTAssertTrue(processor.extractNewMessageIds(from: records).isEmpty)
    }

    func testExtractNewMessageIds_includesMessagesFromInbox() {
        let processor = HistoryProcessor(coreDataStack: .shared)
        let records = [
            makeHistoryRecord(messagesAdded: [
                HistoryMessageAdded(message: makeGmailMessage(id: "m1", labelIds: ["INBOX"])),
                HistoryMessageAdded(message: makeGmailMessage(id: "m2", labelIds: ["INBOX", "UNREAD"]))
            ])
        ]

        let result = processor.extractNewMessageIds(from: records)
        XCTAssertEqual(result, Set(["m1", "m2"]))
    }

    func testExtractNewMessageIds_excludesSpamMessages() {
        let processor = HistoryProcessor(coreDataStack: .shared)
        let records = [
            makeHistoryRecord(messagesAdded: [
                HistoryMessageAdded(message: makeGmailMessage(id: "m1", labelIds: ["SPAM"])),
                HistoryMessageAdded(message: makeGmailMessage(id: "m2", labelIds: ["INBOX"]))
            ])
        ]

        let result = processor.extractNewMessageIds(from: records)
        XCTAssertEqual(result, Set(["m2"]))
    }

    func testExtractNewMessageIds_excludesDrafts() {
        let processor = HistoryProcessor(coreDataStack: .shared)
        let records = [
            makeHistoryRecord(messagesAdded: [
                HistoryMessageAdded(message: makeGmailMessage(id: "m1", labelIds: ["DRAFT"])),
                HistoryMessageAdded(message: makeGmailMessage(id: "m2", labelIds: ["INBOX"]))
            ])
        ]
        XCTAssertEqual(processor.extractNewMessageIds(from: records), Set(["m2"]))
    }

    func testExtractNewMessageIds_excludesTrash() {
        let processor = HistoryProcessor(coreDataStack: .shared)
        let records = [
            makeHistoryRecord(messagesAdded: [
                HistoryMessageAdded(message: makeGmailMessage(id: "m1", labelIds: ["TRASH"])),
                HistoryMessageAdded(message: makeGmailMessage(id: "m2", labelIds: ["INBOX"]))
            ])
        ]
        XCTAssertEqual(processor.extractNewMessageIds(from: records), Set(["m2"]))
    }

    func testExtractNewMessageIds_messagesWithNoLabels_included() {
        let processor = HistoryProcessor(coreDataStack: .shared)
        let records = [
            makeHistoryRecord(messagesAdded: [
                HistoryMessageAdded(message: makeGmailMessage(id: "m1", labelIds: nil))
            ])
        ]
        XCTAssertEqual(processor.extractNewMessageIds(from: records), Set(["m1"]))
    }

    func testExtractNewMessageIds_deduplicatesAcrossRecords() {
        let processor = HistoryProcessor(coreDataStack: .shared)
        let records = [
            makeHistoryRecord(id: "h1", messagesAdded: [
                HistoryMessageAdded(message: makeGmailMessage(id: "m1", labelIds: ["INBOX"]))
            ]),
            makeHistoryRecord(id: "h2", messagesAdded: [
                HistoryMessageAdded(message: makeGmailMessage(id: "m1", labelIds: ["INBOX"])),
                HistoryMessageAdded(message: makeGmailMessage(id: "m2", labelIds: ["INBOX"]))
            ])
        ]

        let result = processor.extractNewMessageIds(from: records)
        XCTAssertEqual(result, Set(["m1", "m2"]))
    }

    // MARK: - hasPendingLocalModification

    func testHasPendingLocalModification_nilLocalModifiedAt_returnsFalse() {
        let context = testStack.makeMainQueueViewContext()
        let message = context.insertTestObject(Message.self)
        message.id = "m1"
        message.localModifiedAt = nil

        XCTAssertFalse(HistoryProcessor.hasPendingLocalModification(message: message))
    }

    func testHasPendingLocalModification_freshLocalModification_returnsTrue() {
        let context = testStack.makeMainQueueViewContext()
        let message = context.insertTestObject(Message.self)
        message.id = "m1"
        message.localModifiedAt = Date().addingTimeInterval(-30) // 30 seconds ago

        XCTAssertTrue(HistoryProcessor.hasPendingLocalModification(message: message))
    }

    func testHasPendingLocalModification_staleLocalModification_returnsFalse() {
        let context = testStack.makeMainQueueViewContext()
        let message = context.insertTestObject(Message.self)
        message.id = "m1"
        // Beyond maxLocalModificationAge (30 minutes)
        message.localModifiedAt = Date().addingTimeInterval(-SyncConfig.maxLocalModificationAge - 60)

        XCTAssertFalse(HistoryProcessor.hasPendingLocalModification(message: message))
    }

    // MARK: - hasConflict (alias semantics)

    func testHasConflict_mirrorsHasPendingLocalModification() {
        let context = testStack.makeMainQueueViewContext()
        let message = context.insertTestObject(Message.self)
        message.id = "m1"
        message.localModifiedAt = Date()

        XCTAssertTrue(HistoryProcessor.hasConflict(message: message, syncStartTime: nil))
        XCTAssertTrue(HistoryProcessor.hasConflict(message: message, syncStartTime: Date().addingTimeInterval(-60)))

        message.localModifiedAt = nil
        XCTAssertFalse(HistoryProcessor.hasConflict(message: message, syncStartTime: nil))
    }
}
