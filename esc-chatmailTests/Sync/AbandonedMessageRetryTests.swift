import XCTest
import CoreData
@testable import esc_chatmail

/// Covers the abandoned-message drain bookkeeping on SyncFailureTracker:
/// which IDs are offered for retry, and how retry outcomes update the store.
final class AbandonedMessageRetryTests: XCTestCase {

    private var testStack: TestCoreDataStack!
    private var coreDataStack: CoreDataStack!
    private var defaults: UserDefaults!
    private var suiteName: String!
    private var sut: SyncFailureTracker!

    override func setUp() async throws {
        try await super.setUp()
        testStack = TestCoreDataStack()
        coreDataStack = CoreDataStack(persistentContainerForTesting: testStack.persistentContainer)
        suiteName = "AbandonedMessageRetryTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        sut = SyncFailureTracker(defaults: defaults, coreDataStack: coreDataStack)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
        sut = nil
        defaults = nil
        suiteName = nil
        coreDataStack = nil
        testStack = nil
        try await super.tearDown()
    }

    // MARK: - Helpers

    private func seedAbandonedMessage(id: String, retryCount: Int16 = 0, abandonedAt: Date = Date()) async throws {
        let context = coreDataStack.newBackgroundContext()
        try await context.perform {
            let record = AbandonedSyncMessage(context: context)
            record.setValue(UUID(), forKey: "id")
            record.setValue(id, forKey: "gmailMessageId")
            record.setValue(abandonedAt, forKey: "abandonedAt")
            record.setValue(retryCount, forKey: "retryCount")
            record.setValue("test", forKey: "reason")
            try context.save()
        }
    }

    private func storedRecords() async throws -> [(id: String, retryCount: Int16)] {
        let context = coreDataStack.newBackgroundContext()
        return try await context.perform {
            let request = NSFetchRequest<AbandonedSyncMessage>(entityName: "AbandonedSyncMessage")
            return try context.fetch(request).compactMap { record in
                guard let id = record.value(forKey: "gmailMessageId") as? String else { return nil }
                return (id: id, retryCount: record.value(forKey: "retryCount") as? Int16 ?? 0)
            }
        }
    }

    // MARK: - fetchRetryableAbandonedMessageIds

    func testFetchRetryable_returnsOldestFirst() async throws {
        try await seedAbandonedMessage(id: "newer", abandonedAt: Date())
        try await seedAbandonedMessage(id: "older", abandonedAt: Date(timeIntervalSinceNow: -3600))

        let ids = await sut.fetchRetryableAbandonedMessageIds()

        XCTAssertEqual(ids, ["older", "newer"])
    }

    func testFetchRetryable_excludesMaxedOutRetryCounts() async throws {
        try await seedAbandonedMessage(id: "retryable", retryCount: Int16(SyncConfig.maxAbandonedMessageRetries - 1))
        try await seedAbandonedMessage(id: "exhausted", retryCount: Int16(SyncConfig.maxAbandonedMessageRetries))

        let ids = await sut.fetchRetryableAbandonedMessageIds()

        XCTAssertEqual(ids, ["retryable"])
    }

    func testFetchRetryable_respectsLimit() async throws {
        for index in 0..<5 {
            try await seedAbandonedMessage(id: "m\(index)", abandonedAt: Date(timeIntervalSinceNow: TimeInterval(index)))
        }

        let ids = await sut.fetchRetryableAbandonedMessageIds(limit: 3)

        XCTAssertEqual(ids, ["m0", "m1", "m2"])
    }

    func testFetchRetryable_emptyStore_returnsEmpty() async {
        let ids = await sut.fetchRetryableAbandonedMessageIds()
        XCTAssertEqual(ids, [])
    }

    // MARK: - recordAbandonedRetryOutcome

    func testRecordOutcome_removesRecoveredAndGoneRecords() async throws {
        try await seedAbandonedMessage(id: "recovered")
        try await seedAbandonedMessage(id: "gone")
        try await seedAbandonedMessage(id: "untouched")

        await sut.recordAbandonedRetryOutcome(recoveredIds: ["recovered"], goneIds: ["gone"], failedIds: [])

        let records = try await storedRecords()
        XCTAssertEqual(records.map(\.id), ["untouched"])
    }

    func testRecordOutcome_incrementsRetryCountForFailures() async throws {
        try await seedAbandonedMessage(id: "failed", retryCount: 2)

        await sut.recordAbandonedRetryOutcome(recoveredIds: [], goneIds: [], failedIds: ["failed"])

        let records = try await storedRecords()
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0].retryCount, 3)
    }

    func testRecordOutcome_failureAgesOutAfterMaxRetries() async throws {
        try await seedAbandonedMessage(id: "flaky")

        for _ in 0..<SyncConfig.maxAbandonedMessageRetries {
            let ids = await sut.fetchRetryableAbandonedMessageIds()
            XCTAssertEqual(ids, ["flaky"])
            await sut.recordAbandonedRetryOutcome(recoveredIds: [], goneIds: [], failedIds: ids)
        }

        let ids = await sut.fetchRetryableAbandonedMessageIds()
        XCTAssertEqual(ids, [], "After \(SyncConfig.maxAbandonedMessageRetries) failed retries the ID is no longer offered")
    }

    func testRecordOutcome_allEmpty_isNoOp() async throws {
        try await seedAbandonedMessage(id: "kept")

        await sut.recordAbandonedRetryOutcome(recoveredIds: [], goneIds: [], failedIds: [])

        let records = try await storedRecords()
        XCTAssertEqual(records.map(\.id), ["kept"])
    }
}
