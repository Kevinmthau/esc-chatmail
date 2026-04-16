import XCTest
@testable import esc_chatmail

final class BatchConfigurationTests: XCTestCase {

    // MARK: - BatchConfiguration presets

    func testDefaultConfiguration_hasExpectedValues() {
        let config = BatchConfiguration.default
        XCTAssertEqual(config.batchSize, 100)
        XCTAssertEqual(config.saveInterval, 500)
        XCTAssertTrue(config.useBatchInsert)
        XCTAssertTrue(config.useBackgroundQueue)
    }

    func testLightweightConfiguration_hasSmallerBatches() {
        let config = BatchConfiguration.lightweight
        XCTAssertLessThan(config.batchSize, BatchConfiguration.default.batchSize)
        XCTAssertLessThan(config.saveInterval, BatchConfiguration.default.saveInterval)
    }

    func testHeavyConfiguration_hasLargerBatches() {
        let config = BatchConfiguration.heavy
        XCTAssertGreaterThan(config.batchSize, BatchConfiguration.default.batchSize)
        XCTAssertGreaterThan(config.saveInterval, BatchConfiguration.default.saveInterval)
    }

    // MARK: - BatchOperationError descriptions

    func testInvalidBatchSize_hasDescription() {
        let error = BatchOperationError.invalidBatchSize
        XCTAssertEqual(error.errorDescription, "Invalid batch size specified")
    }

    func testContextSaveFailure_includesUnderlyingDescription() {
        let underlying = NSError(domain: "Test", code: 1, userInfo: [NSLocalizedDescriptionKey: "save problem"])
        let error = BatchOperationError.contextSaveFailure(underlying)
        XCTAssertTrue(error.errorDescription?.contains("save problem") ?? false)
    }

    func testBatchInsertFailure_includesUnderlyingDescription() {
        let underlying = NSError(domain: "Test", code: 2, userInfo: [NSLocalizedDescriptionKey: "insert problem"])
        let error = BatchOperationError.batchInsertFailure(underlying)
        XCTAssertTrue(error.errorDescription?.contains("insert problem") ?? false)
    }

    func testBatchUpdateFailure_includesUnderlyingDescription() {
        let underlying = NSError(domain: "Test", code: 3, userInfo: [NSLocalizedDescriptionKey: "update problem"])
        let error = BatchOperationError.batchUpdateFailure(underlying)
        XCTAssertTrue(error.errorDescription?.contains("update problem") ?? false)
    }

    // MARK: - ProcessedConversation

    func testProcessedConversation_storesAllFields() {
        let id = UUID()
        let date = Date()
        let conversation = ProcessedConversation(
            id: id,
            keyHash: "hash-1",
            type: "personal",
            displayName: "Alice",
            snippet: "Hi there",
            lastMessageDate: date,
            inboxUnreadCount: 5,
            hasInbox: true,
            latestInboxDate: date
        )

        XCTAssertEqual(conversation.id, id)
        XCTAssertEqual(conversation.keyHash, "hash-1")
        XCTAssertEqual(conversation.type, "personal")
        XCTAssertEqual(conversation.displayName, "Alice")
        XCTAssertEqual(conversation.snippet, "Hi there")
        XCTAssertEqual(conversation.lastMessageDate, date)
        XCTAssertEqual(conversation.inboxUnreadCount, 5)
        XCTAssertTrue(conversation.hasInbox)
        XCTAssertEqual(conversation.latestInboxDate, date)
    }
}
