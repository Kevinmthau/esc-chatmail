import XCTest
import CoreData
@testable import esc_chatmail

/// Characterization of the 3-strikes escape hatch in
/// `SyncFailureTracker.shouldAdvanceHistoryId`: at the max consecutive-failure
/// threshold the tracker advances anyway, persists the tracked IDs as
/// `AbandonedSyncMessage` rows, posts `.syncMessagesAbandoned`, and resets its
/// counters. This is the deadlock-breaker the reliability work must preserve
/// (or knowingly replace) — pinned here before any refactor touches it.
final class SyncFailureTrackerEscapeHatchTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!
    private var testStack: TestCoreDataStack!
    private var coreDataStack: CoreDataStack!
    private var tracker: SyncFailureTracker!

    override func setUp() async throws {
        try await super.setUp()
        suiteName = "SyncFailureTrackerEscapeHatchTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        testStack = TestCoreDataStack()
        coreDataStack = CoreDataStack(persistentContainerForTesting: testStack.persistentContainer)
        tracker = SyncFailureTracker(defaults: defaults, coreDataStack: coreDataStack)
    }

    override func tearDown() async throws {
        defaults?.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        tracker = nil
        coreDataStack = nil
        testStack = nil
        try await super.tearDown()
    }

    func testMaxConsecutiveFailuresAdvancesPersistsAbandonedRowsAndResets() async throws {
        let abandonedNotification = expectation(forNotification: .syncMessagesAbandoned, object: nil) { note in
            (note.userInfo?["count"] as? Int) == 2
        }

        for _ in 0..<SyncConfig.maxConsecutiveSyncFailures {
            await tracker.recordFailure(failedIds: ["stuck-1", "stuck-2"])
        }

        let shouldAdvance = await tracker.shouldAdvanceHistoryId(
            hadFailures: true,
            latestHistoryId: "999"
        )
        XCTAssertTrue(shouldAdvance, "The escape hatch must advance at the threshold to break the deadlock")

        await fulfillment(of: [abandonedNotification], timeout: 5)

        // The tracked IDs land in Core Data with a fresh drain budget.
        let rows = try await fetchAbandonedRows()
        XCTAssertEqual(Set(rows.map(\.gmailMessageId)), ["stuck-1", "stuck-2"])
        for row in rows {
            XCTAssertEqual(row.reason, "Max sync failures reached")
            XCTAssertEqual(row.retryCount, 0, "Re-abandonment must not consume the drain's retry budget")
        }

        // Counters reset because the cursor moved on.
        let consecutive = await tracker.consecutiveFailureCount
        let trackedIds = await tracker.persistentFailedIds
        let lastSuccess = await tracker.lastSuccessfulSyncTime
        XCTAssertEqual(consecutive, 0)
        XCTAssertEqual(trackedIds, [])
        XCTAssertNotNil(lastSuccess)
    }

    /// Exercises the update-existing branch of abandonment: a second trip
    /// through the escape hatch must refresh `abandonedAt`/`reason` on the
    /// existing row while leaving `retryCount` untouched — the drain owns that
    /// counter, and re-abandonment must not consume its retry budget.
    func testReAbandonmentPreservesDrainRetryCount() async throws {
        for _ in 0..<SyncConfig.maxConsecutiveSyncFailures {
            await tracker.recordFailure(failedIds: ["stuck-1"])
        }
        _ = await tracker.shouldAdvanceHistoryId(hadFailures: true, latestHistoryId: "999")

        // Simulate the drain having spent attempts on the row.
        try await setRetryCount(2, forGmailMessageId: "stuck-1")

        // The same message fails again and trips the escape hatch a second time.
        for _ in 0..<SyncConfig.maxConsecutiveSyncFailures {
            await tracker.recordFailure(failedIds: ["stuck-1"])
        }
        let shouldAdvance = await tracker.shouldAdvanceHistoryId(hadFailures: true, latestHistoryId: "1001")
        XCTAssertTrue(shouldAdvance)

        let rows = try await fetchAbandonedRows()
        XCTAssertEqual(rows.count, 1, "Re-abandonment must update the existing row, not duplicate it")
        XCTAssertEqual(rows.first?.retryCount, 2, "Re-abandonment must not reset the drain's retry budget")
    }

    func testBelowThresholdDoesNotAdvanceAndPersistsNothing() async throws {
        for _ in 0..<(SyncConfig.maxConsecutiveSyncFailures - 1) {
            await tracker.recordFailure(failedIds: ["stuck-1"])
        }

        let shouldAdvance = await tracker.shouldAdvanceHistoryId(
            hadFailures: true,
            latestHistoryId: "999"
        )

        XCTAssertFalse(shouldAdvance)
        let rows = try await fetchAbandonedRows()
        XCTAssertTrue(rows.isEmpty, "Below the threshold nothing may be abandoned")
        let consecutive = await tracker.consecutiveFailureCount
        XCTAssertEqual(consecutive, SyncConfig.maxConsecutiveSyncFailures - 1)
    }

    // MARK: - Helpers

    private struct AbandonedRow {
        let gmailMessageId: String?
        let reason: String?
        let retryCount: Int16
    }

    private func setRetryCount(_ count: Int16, forGmailMessageId id: String) async throws {
        let context = coreDataStack.newBackgroundContext()
        try await context.perform {
            let request = NSFetchRequest<NSManagedObject>(entityName: "AbandonedSyncMessage")
            request.predicate = NSPredicate(format: "gmailMessageId == %@", id)
            let row = try XCTUnwrap(try context.fetch(request).first)
            row.setValue(count, forKey: "retryCount")
            try context.save()
        }
    }

    private func fetchAbandonedRows() async throws -> [AbandonedRow] {
        let context = coreDataStack.newBackgroundContext()
        return await context.perform {
            let request = NSFetchRequest<NSManagedObject>(entityName: "AbandonedSyncMessage")
            request.includesPendingChanges = false
            let records = (try? context.fetch(request)) ?? []
            return records.map {
                AbandonedRow(
                    gmailMessageId: $0.value(forKey: "gmailMessageId") as? String,
                    reason: $0.value(forKey: "reason") as? String,
                    retryCount: $0.value(forKey: "retryCount") as? Int16 ?? -1
                )
            }
        }
    }
}
