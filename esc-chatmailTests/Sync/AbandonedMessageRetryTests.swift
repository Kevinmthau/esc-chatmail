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
    private var clock: FakeSyncClock!
    private var sut: SyncFailureTracker!

    override func setUp() async throws {
        try await super.setUp()
        // SQLite store: the drain predicate's `state == nil` disjunct is
        // load-bearing under SQL ternary logic (NULL <> 'deferred' filters the
        // row OUT on SQLite), while the in-memory store's Foundation semantics
        // evaluate nil != "deferred" as TRUE — an in-memory run would keep the
        // legacy-row tests green even with the disjunct deleted.
        testStack = TestCoreDataStack(storeKind: .sqlite)
        coreDataStack = CoreDataStack(persistentContainerForTesting: testStack.persistentContainer)
        suiteName = "AbandonedMessageRetryTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        // These tests target post-migration behavior; the legacy retryCount reset
        // is exercised explicitly in the migration test below.
        defaults.set(true, forKey: SyncConfig.abandonedRetryCountResetKey)
        clock = FakeSyncClock()
        sut = SyncFailureTracker(defaults: defaults, coreDataStack: coreDataStack, clock: clock)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
        sut = nil
        clock = nil
        defaults = nil
        suiteName = nil
        coreDataStack = nil
        testStack = nil
        try await super.tearDown()
    }

    // MARK: - Helpers

    private func seedAbandonedMessage(
        id: String,
        retryCount: Int16 = 0,
        abandonedAt: Date = Date(),
        state: String? = nil,
        nextRetryAt: Date? = nil
    ) async throws {
        let context = coreDataStack.newBackgroundContext()
        try await context.perform {
            let record = AbandonedSyncMessage(context: context)
            record.setValue(UUID(), forKey: "id")
            record.setValue(id, forKey: "gmailMessageId")
            record.setValue(abandonedAt, forKey: "abandonedAt")
            record.setValue(retryCount, forKey: "retryCount")
            record.setValue("test", forKey: "reason")
            record.setValue(state, forKey: "state")
            record.setValue(nextRetryAt, forKey: "nextRetryAt")
            try context.save()
        }
    }

    private func storedNextRetryAt(id: String) async throws -> Date? {
        let context = coreDataStack.newBackgroundContext()
        return try await context.perform {
            let request = NSFetchRequest<AbandonedSyncMessage>(entityName: "AbandonedSyncMessage")
            request.predicate = NSPredicate(format: "gmailMessageId == %@", id)
            return try context.fetch(request).first?.value(forKey: "nextRetryAt") as? Date
        }
    }

    /// Stages the outcome into a fresh context and saves it — the caller-side
    /// shape of the sync run's final save.
    private func applyRetryOutcome(recoveredIds: [String], goneIds: [String], failedIds: [String]) async throws {
        let context = coreDataStack.newBackgroundContext()
        await sut.stageAbandonedRetryOutcome(
            recoveredIds: recoveredIds,
            goneIds: goneIds,
            failedIds: failedIds,
            in: context
        )
        try await coreDataStack.saveAsync(context: context)
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

    func testFetchRetryable_excludesDeferredRows() async throws {
        // Deferred rows are still covered by the frozen cursor: the normal
        // re-scan of the same history window retries them, so offering them to
        // the drain would fetch them twice per run and burn their retry budget
        // before abandonment.
        try await seedAbandonedMessage(id: "still-tracked", state: AbandonedSyncMessage.State.deferred.rawValue)
        try await seedAbandonedMessage(id: "legacy-abandoned", state: nil)
        try await seedAbandonedMessage(id: "abandoned", state: AbandonedSyncMessage.State.abandoned.rawValue)

        let ids = await sut.fetchRetryableAbandonedMessageIds()

        XCTAssertEqual(Set(ids), ["legacy-abandoned", "abandoned"], "Only abandoned rows (nil state = legacy) are drain-eligible")
    }

    func testFetchRetryable_resetsLegacyRetryCountsOnce() async throws {
        // Legacy records counted re-abandonments in retryCount and can sit at or
        // above the drain's cap without any drain attempt having run.
        defaults.set(false, forKey: SyncConfig.abandonedRetryCountResetKey)
        try await seedAbandonedMessage(id: "legacy", retryCount: Int16(SyncConfig.maxAbandonedMessageRetries + 2))

        let ids = await sut.fetchRetryableAbandonedMessageIds()

        XCTAssertEqual(ids, ["legacy"], "Legacy retryCount must be reset so the drain gets its full budget")
        let records = try await storedRecords()
        XCTAssertEqual(records.first?.retryCount, 0)
        XCTAssertTrue(defaults.bool(forKey: SyncConfig.abandonedRetryCountResetKey), "Reset runs once and latches")
    }

    // MARK: - stageAbandonedRetryOutcome

    // MARK: - nextRetryAt pacing

    func testRecordOutcome_failedRetryStampsPacedNextRetryAt() async throws {
        try await seedAbandonedMessage(id: "paced")

        try await applyRetryOutcome(recoveredIds: [], goneIds: [], failedIds: ["paced"])

        let stamped = try await storedNextRetryAt(id: "paced")
        XCTAssertEqual(
            stamped,
            clock.now().addingTimeInterval(SyncConfig.abandonedRetryBackoffBase),
            "The first failed drain attempt paces the next one by the base backoff"
        )
    }

    /// Dual pin: paced rows are excluded until their backoff elapses, AND a
    /// paced-empty fetch must not latch the skip-the-fetch fast path closed —
    /// otherwise the row would never be offered again once eligible.
    func testFetchRetryable_excludesPacedRowsUntilBackoffElapses() async throws {
        try await seedAbandonedMessage(
            id: "paced",
            retryCount: 1,
            nextRetryAt: clock.now().addingTimeInterval(SyncConfig.abandonedRetryBackoffBase)
        )

        let before = await sut.fetchRetryableAbandonedMessageIds()
        XCTAssertEqual(before, [], "A row inside its backoff window must not be offered")

        clock.advance(by: SyncConfig.abandonedRetryBackoffBase + 1)
        let after = await sut.fetchRetryableAbandonedMessageIds()
        XCTAssertEqual(
            after, ["paced"],
            "An elapsed backoff must re-offer the row — pacing must not latch the fast path closed"
        )
    }

    func testFetchRetryable_nilNextRetryAtRemainsImmediatelyEligible() async throws {
        try await seedAbandonedMessage(id: "fresh")

        let ids = await sut.fetchRetryableAbandonedMessageIds()

        XCTAssertEqual(
            ids, ["fresh"],
            "Fresh abandonments and legacy rows carry nil nextRetryAt; the nil disjunct is load-bearing on SQLite"
        )
    }

    func testRetryBackoffIntervalIsExponentialAndCapped() {
        XCTAssertEqual(SyncFailureTracker.retryBackoffInterval(forRetryCount: 1), 900)
        XCTAssertEqual(SyncFailureTracker.retryBackoffInterval(forRetryCount: 2), 3_600)
        XCTAssertEqual(SyncFailureTracker.retryBackoffInterval(forRetryCount: 3), 14_400)
        XCTAssertEqual(SyncFailureTracker.retryBackoffInterval(forRetryCount: 4), 43_200)
        XCTAssertEqual(
            SyncFailureTracker.retryBackoffInterval(forRetryCount: 10), 43_200,
            "The backoff must stay capped"
        )
    }

    func testStageOutcome_isStagedOnly_storeUntouchedUntilCallerSaves() async throws {
        // The outcome must commit with the caller's save — atomically with the
        // recovered messages — so a failed save leaves every record for the
        // next drain.
        try await seedAbandonedMessage(id: "recovered")
        try await seedAbandonedMessage(id: "failed", retryCount: 1)

        let context = coreDataStack.newBackgroundContext()
        await sut.stageAbandonedRetryOutcome(
            recoveredIds: ["recovered"],
            goneIds: [],
            failedIds: ["failed"],
            in: context
        )

        let records = try await storedRecords()
        XCTAssertEqual(
            Set(records.map(\.id)), ["recovered", "failed"],
            "Without the caller's save, no record may be removed"
        )
        XCTAssertEqual(
            records.first(where: { $0.id == "failed" })?.retryCount, 1,
            "Without the caller's save, no retry budget may be spent"
        )
    }

    func testRecordOutcome_removesRecoveredAndGoneRecords() async throws {
        try await seedAbandonedMessage(id: "recovered")
        try await seedAbandonedMessage(id: "gone")
        try await seedAbandonedMessage(id: "untouched")

        try await applyRetryOutcome(recoveredIds: ["recovered"], goneIds: ["gone"], failedIds: [])

        let records = try await storedRecords()
        XCTAssertEqual(records.map(\.id), ["untouched"])
    }

    func testRecordOutcome_incrementsRetryCountForFailures() async throws {
        try await seedAbandonedMessage(id: "failed", retryCount: 2)

        try await applyRetryOutcome(recoveredIds: [], goneIds: [], failedIds: ["failed"])

        let records = try await storedRecords()
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0].retryCount, 3)
    }

    func testRecordOutcome_failureAgesOutAfterMaxRetries() async throws {
        try await seedAbandonedMessage(id: "flaky")

        for attempt in 0..<SyncConfig.maxAbandonedMessageRetries {
            let ids = await sut.fetchRetryableAbandonedMessageIds()
            XCTAssertEqual(ids, ["flaky"])
            try await applyRetryOutcome(recoveredIds: [], goneIds: [], failedIds: ids)
            // Each failed attempt paces the next one; the drain that ages the
            // row out only sees it again after its backoff elapses.
            clock.advance(
                by: SyncFailureTracker.retryBackoffInterval(forRetryCount: attempt + 1) + 1
            )
        }

        let ids = await sut.fetchRetryableAbandonedMessageIds()
        XCTAssertEqual(ids, [], "After \(SyncConfig.maxAbandonedMessageRetries) failed retries the ID is no longer offered")

        let records = try await storedRecords()
        XCTAssertTrue(records.isEmpty, "Records that hit the retry cap are deleted, not kept as dead rows")
    }

    func testRecordOutcome_deletesRecordWhenFailureReachesCap() async throws {
        try await seedAbandonedMessage(id: "last-chance", retryCount: Int16(SyncConfig.maxAbandonedMessageRetries - 1))

        try await applyRetryOutcome(recoveredIds: [], goneIds: [], failedIds: ["last-chance"])

        let records = try await storedRecords()
        XCTAssertTrue(records.isEmpty, "A failure that brings retryCount to the cap deletes the record")
    }

    func testRecordOutcome_allEmpty_isNoOp() async throws {
        try await seedAbandonedMessage(id: "kept")

        try await applyRetryOutcome(recoveredIds: [], goneIds: [], failedIds: [])

        let records = try await storedRecords()
        XCTAssertEqual(records.map(\.id), ["kept"])
    }
}
