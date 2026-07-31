import XCTest
import CoreData
@testable import esc_chatmail

/// Unit coverage for SyncFailureTracker's staged ledger model: failed IDs are
/// staged as durable deferred `AbandonedSyncMessage` rows in the CALLER's
/// context (never saved by the tracker), advancement decisions stage the
/// matching transition, and success-side UserDefaults mutations happen only in
/// `commit(_:)` after the caller's save.
final class SyncFailureTrackerTests: XCTestCase {

    private var defaults: UserDefaults!
    private var suiteName: String!
    private var testStack: TestCoreDataStack!
    private var coreDataStack: CoreDataStack!
    private var sut: SyncFailureTracker!

    override func setUp() async throws {
        try await super.setUp()
        suiteName = "SyncFailureTrackerTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        testStack = TestCoreDataStack()
        coreDataStack = CoreDataStack(persistentContainerForTesting: testStack.persistentContainer)
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

    private struct LedgerRow {
        let gmailMessageId: String?
        let state: String?
        let failureClass: String?
        let sourceHistoryId: String?
        let reason: String?
        let retryCount: Int16
    }

    /// Rows as durably committed — pending changes in any live context are
    /// invisible here, which is exactly what the atomicity assertions need.
    private func committedRows() async -> [LedgerRow] {
        let context = coreDataStack.newBackgroundContext()
        return await context.perform {
            let request = NSFetchRequest<NSManagedObject>(entityName: "AbandonedSyncMessage")
            request.includesPendingChanges = false
            let records = (try? context.fetch(request)) ?? []
            return records.map {
                LedgerRow(
                    gmailMessageId: $0.value(forKey: "gmailMessageId") as? String,
                    state: $0.value(forKey: "state") as? String,
                    failureClass: $0.value(forKey: "failureClass") as? String,
                    sourceHistoryId: $0.value(forKey: "sourceHistoryId") as? String,
                    reason: $0.value(forKey: "reason") as? String,
                    retryCount: $0.value(forKey: "retryCount") as? Int16 ?? -1
                )
            }
        }
    }

    private func seedRow(
        id: String,
        state: String?,
        retryCount: Int16 = 0,
        reason: String? = nil
    ) async throws {
        let context = coreDataStack.newBackgroundContext()
        try await context.perform {
            let record = AbandonedSyncMessage(context: context)
            record.setValue(UUID(), forKey: "id")
            record.setValue(id, forKey: "gmailMessageId")
            record.setValue(Date(), forKey: "abandonedAt")
            record.setValue(retryCount, forKey: "retryCount")
            record.setValue(state, forKey: "state")
            record.setValue(reason, forKey: "reason")
            try context.save()
        }
    }

    // MARK: - Initial state

    func testInitialState_noRecordedFailures() async {
        let count = await sut.consecutiveFailureCount
        XCTAssertEqual(count, 0)
        let rows = await committedRows()
        XCTAssertTrue(rows.isEmpty)
    }

    func testInitialState_lastSuccessfulSyncTimeIsNil() async {
        let time = await sut.lastSuccessfulSyncTime
        XCTAssertNil(time)
    }

    // MARK: - recordSuccess

    func testRecordSuccess_resetsFailureCounter() async throws {
        let context = coreDataStack.newBackgroundContext()
        await sut.recordFailure(fetchFailedIds: ["a"], in: context)
        await sut.recordSuccess()

        let count = await sut.consecutiveFailureCount
        XCTAssertEqual(count, 0)
    }

    func testRecordSuccess_updatesLastSuccessfulSyncTime() async {
        let before = Date()
        await sut.recordSuccess()
        let time = await sut.lastSuccessfulSyncTime

        XCTAssertNotNil(time)
        XCTAssertGreaterThanOrEqual(time!.timeIntervalSince1970, before.addingTimeInterval(-1).timeIntervalSince1970)
    }

    // MARK: - recordFailure staging

    func testRecordFailure_emptyIds_noChange() async {
        let context = coreDataStack.newBackgroundContext()
        await sut.recordFailure(fetchFailedIds: [], in: context)

        let count = await sut.consecutiveFailureCount
        XCTAssertEqual(count, 0)
        let hasChanges = await context.perform { context.hasChanges }
        XCTAssertFalse(hasChanges, "An empty failing set must stage nothing")
    }

    func testRecordFailure_stagesOnly_storeUntouchedUntilCallerSaves() async {
        let context = coreDataStack.newBackgroundContext()
        await sut.recordFailure(fetchFailedIds: ["id-1"], in: context)

        let count = await sut.consecutiveFailureCount
        XCTAssertEqual(count, 1)
        let rows = await committedRows()
        XCTAssertTrue(
            rows.isEmpty,
            "The tracker must never save; rows commit only with the caller's final save"
        )
    }

    func testRecordFailure_savedContextCommitsDeferredRowsWithMetadata() async throws {
        let context = coreDataStack.newBackgroundContext()
        await sut.recordFailure(
            fetchFailedIds: ["fetch-1"],
            persistenceFailedIds: ["persist-1"],
            sourceHistoryId: "1000",
            in: context
        )
        try await coreDataStack.saveAsync(context: context)

        let rows = await committedRows()
        XCTAssertEqual(rows.count, 2)
        let byId = Dictionary(uniqueKeysWithValues: rows.map { ($0.gmailMessageId ?? "", $0) })
        XCTAssertEqual(byId["fetch-1"]?.state, AbandonedSyncMessage.State.deferred.rawValue)
        XCTAssertEqual(byId["fetch-1"]?.failureClass, AbandonedSyncMessage.FailureClass.fetchFailed.rawValue)
        XCTAssertEqual(byId["fetch-1"]?.sourceHistoryId, "1000")
        XCTAssertEqual(byId["fetch-1"]?.retryCount, 0)
        XCTAssertEqual(byId["persist-1"]?.state, AbandonedSyncMessage.State.deferred.rawValue)
        XCTAssertEqual(byId["persist-1"]?.failureClass, AbandonedSyncMessage.FailureClass.persistenceFailed.rawValue)
        XCTAssertEqual(byId["persist-1"]?.sourceHistoryId, "1000")
    }

    func testRecordFailure_laterRunReplacesTrackedSet() async throws {
        // Each failing run reports its complete failing set over the same
        // frozen window; an ID absent from the latest run either succeeded or
        // is gone, so keeping it would spuriously abandon recovered messages.
        let firstRun = coreDataStack.newBackgroundContext()
        await sut.recordFailure(fetchFailedIds: ["a", "b"], in: firstRun)
        try await coreDataStack.saveAsync(context: firstRun)

        let secondRun = coreDataStack.newBackgroundContext()
        await sut.recordFailure(fetchFailedIds: ["b", "c"], in: secondRun)
        try await coreDataStack.saveAsync(context: secondRun)

        let count = await sut.consecutiveFailureCount
        XCTAssertEqual(count, 2)
        let rows = await committedRows()
        XCTAssertEqual(
            Set(rows.map { $0.gmailMessageId ?? "" }), ["b", "c"],
            "Recovered IDs must drop out of tracking"
        )
    }

    func testRecordFailure_duplicateIdsWithinRun_notDoubled() async throws {
        let context = coreDataStack.newBackgroundContext()
        await sut.recordFailure(fetchFailedIds: ["a", "b", "b", "a", "c"], in: context)
        try await coreDataStack.saveAsync(context: context)

        let rows = await committedRows()
        XCTAssertEqual(Set(rows.map { $0.gmailMessageId ?? "" }), ["a", "b", "c"])
    }

    func testRecordFailure_hugeBatchKeepsEveryTrackedId() async throws {
        // Tracked IDs must never be truncated: dropped IDs would be silently
        // lost when the escape hatch advances the cursor past them. Bounding
        // happens at the drain (maxAbandonedMessagesPerSync), not here.
        let oversized = (0..<25).map { "id-\($0)" }

        let context = coreDataStack.newBackgroundContext()
        await sut.recordFailure(fetchFailedIds: oversized, in: context)
        try await coreDataStack.saveAsync(context: context)

        let rows = await committedRows()
        XCTAssertEqual(
            Set(rows.map { $0.gmailMessageId ?? "" }), Set(oversized),
            "Every failed ID must stay tracked until durably abandoned"
        )
    }

    func testRecordFailure_reTrackingAbandonedRowPreservesDrainRetryCount() async throws {
        // A previously abandoned message that reappears in a failing window is
        // tracked again (deferred), but the drain owns retryCount.
        try await seedRow(id: "back-again", state: AbandonedSyncMessage.State.abandoned.rawValue, retryCount: 2)

        let context = coreDataStack.newBackgroundContext()
        await sut.recordFailure(fetchFailedIds: ["back-again"], in: context)
        try await coreDataStack.saveAsync(context: context)

        let rows = await committedRows()
        XCTAssertEqual(rows.count, 1, "Re-tracking must update the existing row, not duplicate it")
        XCTAssertEqual(rows.first?.state, AbandonedSyncMessage.State.deferred.rawValue)
        XCTAssertEqual(rows.first?.retryCount, 2, "Re-tracking must not reset the drain's retry budget")
    }

    func testRecordFailure_reconcileLeavesAbandonedRowsAlone() async throws {
        // Reconciliation replaces only the DEFERRED set; abandoned rows belong
        // to the drain and are invisible to the frozen-cursor re-scan.
        try await seedRow(id: "drained-later", state: AbandonedSyncMessage.State.abandoned.rawValue)
        try await seedRow(id: "legacy-nil-state", state: nil)

        let context = coreDataStack.newBackgroundContext()
        await sut.recordFailure(fetchFailedIds: ["fresh"], in: context)
        try await coreDataStack.saveAsync(context: context)

        let rows = await committedRows()
        let byId = Dictionary(uniqueKeysWithValues: rows.map { ($0.gmailMessageId ?? "", $0) })
        XCTAssertEqual(rows.count, 3)
        XCTAssertEqual(byId["drained-later"]?.state, AbandonedSyncMessage.State.abandoned.rawValue)
        XCTAssertNil(byId["legacy-nil-state"]?.state)
        XCTAssertEqual(byId["fresh"]?.state, AbandonedSyncMessage.State.deferred.rawValue)
    }

    // MARK: - planHistoryAdvance

    func testPlanAdvance_noFailures_stagesDeferredCleanupAndAdvances() async throws {
        let failingRun = coreDataStack.newBackgroundContext()
        await sut.recordFailure(fetchFailedIds: ["recovered-later"], in: failingRun)
        try await coreDataStack.saveAsync(context: failingRun)

        let cleanRun = coreDataStack.newBackgroundContext()
        let plan = await sut.planHistoryAdvance(hadFailures: false, in: cleanRun)

        XCTAssertTrue(plan.shouldAdvance)
        XCTAssertEqual(plan.outcome, .advancedClean)
        var rows = await committedRows()
        XCTAssertEqual(rows.count, 1, "Cleanup is staged, not saved — the row must survive until the caller's save")

        try await coreDataStack.saveAsync(context: cleanRun)
        rows = await committedRows()
        XCTAssertTrue(rows.isEmpty, "The clean run's save removes recovered deferred rows")
    }

    func testPlanAdvance_belowMax_holds() async {
        let context = coreDataStack.newBackgroundContext()
        await sut.recordFailure(fetchFailedIds: ["x"], in: context)

        let plan = await sut.planHistoryAdvance(hadFailures: true, in: context)

        XCTAssertFalse(plan.shouldAdvance)
        XCTAssertEqual(plan.outcome, .held)
        let count = await sut.consecutiveFailureCount
        XCTAssertEqual(count, 1)
    }

    func testCommit_heldPlan_changesNothing() async {
        let context = coreDataStack.newBackgroundContext()
        await sut.recordFailure(fetchFailedIds: ["x"], in: context)

        await sut.commit(.held)

        let count = await sut.consecutiveFailureCount
        XCTAssertEqual(count, 1, "A held run must not reset the failure counter")
        let time = await sut.lastSuccessfulSyncTime
        XCTAssertNil(time)
    }

    func testCommit_appliesSuccessStateOnlyWhenCalled() async throws {
        let context = coreDataStack.newBackgroundContext()
        await sut.recordFailure(fetchFailedIds: ["x"], in: context)
        let plan = await sut.planHistoryAdvance(hadFailures: false, in: context)
        try await coreDataStack.saveAsync(context: context)

        // The save alone must not touch the tracker's UserDefaults state —
        // if the caller's save had failed, discarding the plan keeps everything.
        var count = await sut.consecutiveFailureCount
        XCTAssertEqual(count, 1, "Success state must not change before commit")

        await sut.commit(plan)

        count = await sut.consecutiveFailureCount
        XCTAssertEqual(count, 0)
        let time = await sut.lastSuccessfulSyncTime
        XCTAssertNotNil(time)
    }

    // MARK: - reset

    func testReset_clearsCounter() async {
        let context = coreDataStack.newBackgroundContext()
        await sut.recordFailure(fetchFailedIds: ["a", "b"], in: context)

        await sut.reset()

        let count = await sut.consecutiveFailureCount
        XCTAssertEqual(count, 0)
    }
}
