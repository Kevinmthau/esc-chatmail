import XCTest
import CoreData
@testable import esc_chatmail

/// Characterization of the 3-strikes escape hatch at its post-consolidation
/// boundary: at the max consecutive-failure threshold the tracker STAGES the
/// deferred→abandoned transition into the caller's context, the caller's final
/// save commits rows and cursor together, and only `commit(_:)` afterwards
/// resets counters and posts `.syncMessagesAbandoned`. This is the
/// deadlock-breaker the reliability work must preserve.
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

    /// Runs `count` failing runs, each staging into its own context and saving —
    /// the shape of consecutive real sync runs over a frozen cursor.
    private func recordFailingRuns(_ count: Int, failedIds: [String]) async throws {
        for _ in 0..<count {
            let context = coreDataStack.newBackgroundContext()
            await tracker.recordFailure(fetchFailedIds: failedIds, in: context)
            try await coreDataStack.saveAsync(context: context)
        }
    }

    func testMaxConsecutiveFailuresAdvancesPersistsAbandonedRowsAndResets() async throws {
        let abandonedNotification = expectation(forNotification: .syncMessagesAbandoned, object: nil) { note in
            (note.userInfo?["count"] as? Int) == 2
        }

        try await recordFailingRuns(
            SyncConfig.maxConsecutiveSyncFailures,
            failedIds: ["stuck-1", "stuck-2"]
        )

        let hatchRun = coreDataStack.newBackgroundContext()
        let plan = await tracker.planHistoryAdvance(hadFailures: true, in: hatchRun)
        XCTAssertTrue(plan.shouldAdvance, "The escape hatch must advance at the threshold to break the deadlock")
        XCTAssertEqual(plan.outcome, .advancedAbandoning(count: 2))

        // Staged only: until the caller's final save the durable rows are
        // still deferred — a failed save must leave the ledger untransitioned.
        var rows = try await fetchAbandonedRows()
        XCTAssertTrue(
            rows.allSatisfy { $0.state == AbandonedSyncMessage.State.deferred.rawValue },
            "The abandonment transition must not commit before the caller's save"
        )

        try await coreDataStack.saveAsync(context: hatchRun)
        await tracker.commit(plan)

        await fulfillment(of: [abandonedNotification], timeout: 5)

        // The tracked IDs are now durably abandoned with a fresh drain budget.
        rows = try await fetchAbandonedRows()
        XCTAssertEqual(Set(rows.map(\.gmailMessageId)), ["stuck-1", "stuck-2"])
        for row in rows {
            XCTAssertEqual(row.state, AbandonedSyncMessage.State.abandoned.rawValue)
            XCTAssertEqual(row.reason, "Max sync failures reached")
            XCTAssertEqual(row.retryCount, 0, "Abandonment must not consume the drain's retry budget")
        }

        // Counters reset because the cursor moved on.
        let consecutive = await tracker.consecutiveFailureCount
        let lastSuccess = await tracker.lastSuccessfulSyncTime
        XCTAssertEqual(consecutive, 0)
        XCTAssertNotNil(lastSuccess)
    }

    /// Exercises re-abandonment: a second trip through the escape hatch must
    /// refresh `abandonedAt`/`reason` on the existing row while leaving
    /// `retryCount` untouched — the drain owns that counter, and re-abandonment
    /// must not consume its retry budget.
    func testReAbandonmentPreservesDrainRetryCount() async throws {
        try await recordFailingRuns(SyncConfig.maxConsecutiveSyncFailures, failedIds: ["stuck-1"])
        let firstHatch = coreDataStack.newBackgroundContext()
        let firstPlan = await tracker.planHistoryAdvance(hadFailures: true, in: firstHatch)
        try await coreDataStack.saveAsync(context: firstHatch)
        await tracker.commit(firstPlan)

        // Simulate the drain having spent attempts on the row.
        try await setRetryCount(2, forGmailMessageId: "stuck-1")

        // The same message fails again and trips the escape hatch a second time.
        try await recordFailingRuns(SyncConfig.maxConsecutiveSyncFailures, failedIds: ["stuck-1"])
        let secondHatch = coreDataStack.newBackgroundContext()
        let secondPlan = await tracker.planHistoryAdvance(hadFailures: true, in: secondHatch)
        XCTAssertTrue(secondPlan.shouldAdvance)
        try await coreDataStack.saveAsync(context: secondHatch)
        await tracker.commit(secondPlan)

        let rows = try await fetchAbandonedRows()
        XCTAssertEqual(rows.count, 1, "Re-abandonment must update the existing row, not duplicate it")
        XCTAssertEqual(rows.first?.state, AbandonedSyncMessage.State.abandoned.rawValue)
        XCTAssertEqual(rows.first?.retryCount, 2, "Re-abandonment must not reset the drain's retry budget")
    }

    /// A run whose final save fails discards the staged transition with the
    /// context: rows stay deferred, the counter stays at the threshold, and the
    /// hatch re-arms on the next run — nothing was cleared prematurely.
    func testDiscardedPlanLeavesLedgerAndCountersForRetry() async throws {
        try await recordFailingRuns(SyncConfig.maxConsecutiveSyncFailures, failedIds: ["stuck-1"])

        let failedRun = coreDataStack.newBackgroundContext()
        let plan = await tracker.planHistoryAdvance(hadFailures: true, in: failedRun)
        XCTAssertTrue(plan.shouldAdvance)
        // The caller's save fails here; the plan is discarded, never committed.

        let rows = try await fetchAbandonedRows()
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(
            rows.first?.state, AbandonedSyncMessage.State.deferred.rawValue,
            "A failed save must leave the durable ledger untransitioned"
        )
        let consecutive = await tracker.consecutiveFailureCount
        XCTAssertEqual(
            consecutive, SyncConfig.maxConsecutiveSyncFailures,
            "Failure tracking must survive so the hatch retries next run"
        )

        // Next run: the hatch arms again over the same durable rows.
        let retryRun = coreDataStack.newBackgroundContext()
        let retryPlan = await tracker.planHistoryAdvance(hadFailures: true, in: retryRun)
        XCTAssertEqual(retryPlan.outcome, .advancedAbandoning(count: 1))
    }

    /// A failed ledger READ must block the escape hatch: advancing would move
    /// the cursor past IDs whose durable rows could not be transitioned.
    func testFailedLedgerReadBlocksEscapeHatch() async throws {
        defaults.set(SyncConfig.maxConsecutiveSyncFailures, forKey: SyncConfig.consecutiveFailuresKey)
        let failingContext = try FailingReadStore.makeFailingContext()

        let plan = await tracker.planHistoryAdvance(hadFailures: true, in: failingContext)

        XCTAssertEqual(plan.outcome, .held, "The cursor must stay frozen when the ledger cannot be read")
        let consecutive = await tracker.consecutiveFailureCount
        XCTAssertEqual(
            consecutive, SyncConfig.maxConsecutiveSyncFailures,
            "Failure tracking must survive so the hatch retries next run"
        )
    }

    /// A clean network run must not advance past durable deferred rows when
    /// the ledger itself cannot be read. Treating the failed fetch as an empty
    /// result would make those rows unreachable by either recovery path.
    func testFailedLedgerReadBlocksCleanAdvance() async throws {
        let failingContext = try FailingReadStore.makeFailingContext()

        let plan = await tracker.planHistoryAdvance(hadFailures: false, in: failingContext)

        XCTAssertEqual(plan.outcome, .held, "The cursor must stay frozen when clean-run ledger cleanup cannot be planned")
    }

    /// Once the cursor and deferred→abandoned rows are durably saved, task
    /// cancellation must not skip the matching tracker commit. Reconciliation
    /// bookkeeping remains cancellation-sensitive because it is not part of
    /// the durable sync transaction.
    func testPostSaveCancellationStillCommitsAbandonmentPlan() async throws {
        let abandonedNotification = expectation(forNotification: .syncMessagesAbandoned, object: nil) { note in
            (note.userInfo?["count"] as? Int) == 1
        }
        let saveCompleted = expectation(description: "durable save completed")
        let saveGate = SyncPersistenceCancellationGate()

        let initiallyRetryable = await tracker.fetchRetryableAbandonedMessageIds()
        XCTAssertTrue(initiallyRetryable.isEmpty, "Prime the tracker's empty-store fast path")

        try await recordFailingRuns(SyncConfig.maxConsecutiveSyncFailures, failedIds: ["stuck-1"])
        let hatchRun = coreDataStack.newBackgroundContext()
        let plan = await tracker.planHistoryAdvance(hadFailures: true, in: hatchRun)
        XCTAssertEqual(plan.outcome, .advancedAbandoning(count: 1))

        var didRecordReconciliation = false
        let task = Task {
            try await IncrementalSyncOrchestrator.finalizePersistence(
                labelReconciliationOutcome: .completed,
                save: {
                    try await self.coreDataStack.saveAsync(context: hatchRun)
                    saveCompleted.fulfill()
                    await saveGate.wait()
                },
                commit: {
                    await self.tracker.commit(plan)
                },
                recordReconciliation: {
                    didRecordReconciliation = true
                }
            )
        }

        await fulfillment(of: [saveCompleted], timeout: 5)
        task.cancel()
        await saveGate.open()

        do {
            try await task.value
            XCTFail("Expected cancellation after the durable save")
        } catch is CancellationError {
            // Expected after the non-cancellable commit closure finishes.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        await fulfillment(of: [abandonedNotification], timeout: 5)
        XCTAssertFalse(didRecordReconciliation)
        let consecutiveFailureCount = await tracker.consecutiveFailureCount
        XCTAssertEqual(consecutiveFailureCount, 0)

        let rows = try await fetchAbandonedRows()
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.state, AbandonedSyncMessage.State.abandoned.rawValue)

        let retryableAfterCommit = await tracker.fetchRetryableAbandonedMessageIds()
        XCTAssertEqual(retryableAfterCommit, ["stuck-1"], "The post-save commit must re-arm the abandoned-message drain")
    }

    /// A failed ledger read during recordFailure still counts the strike but
    /// stages nothing — so a later hatch, reading through a WORKING context,
    /// must hold rather than abandon a stale (or empty) deferred set: the
    /// current run's failing IDs never reached the ledger.
    func testStagingFailureLatchBlocksHatchOverStaleRows() async throws {
        // A previous run durably tracked an older failing set.
        try await recordFailingRuns(SyncConfig.maxConsecutiveSyncFailures - 1, failedIds: ["stale-1"])

        // The threshold-crossing run cannot read the ledger: the strike counts,
        // the staging is skipped.
        let failingContext = try FailingReadStore.makeFailingContext()
        await tracker.recordFailure(fetchFailedIds: ["fresh-1"], in: failingContext)
        let consecutive = await tracker.consecutiveFailureCount
        XCTAssertEqual(
            consecutive, SyncConfig.maxConsecutiveSyncFailures,
            "The strike must count even when staging is skipped, or a persistently failing store would freeze the cursor with the hatch never arming"
        )

        // The hatch fetch itself succeeds (working context) — but it must not
        // abandon stale-1 and advance past fresh-1, which has no durable row.
        let hatchRun = coreDataStack.newBackgroundContext()
        let plan = await tracker.planHistoryAdvance(hadFailures: true, in: hatchRun)
        XCTAssertEqual(plan.outcome, .held, "An unstaged failing set must hold the cursor")

        let rows = try await fetchAbandonedRows()
        XCTAssertEqual(rows.map(\.gmailMessageId), ["stale-1"])
        XCTAssertEqual(
            rows.first?.state, AbandonedSyncMessage.State.deferred.rawValue,
            "The stale set must not be abandoned in place of the unstaged one"
        )

        // The next failing run stages successfully (frozen cursor re-scans the
        // same window, so its set is complete) — the latch clears and the
        // hatch fires over the now-durable set.
        let recoveredRun = coreDataStack.newBackgroundContext()
        await tracker.recordFailure(fetchFailedIds: ["stale-1", "fresh-1"], in: recoveredRun)
        let retryPlan = await tracker.planHistoryAdvance(hadFailures: true, in: recoveredRun)
        XCTAssertEqual(retryPlan.outcome, .advancedAbandoning(count: 2))
    }

    /// The hatch with real failures but ZERO deferred rows signals a ledger
    /// anomaly: advancing would skip the failing IDs with no durable record.
    func testHatchHoldsWhenLedgerHasNoDeferredRows() async throws {
        defaults.set(SyncConfig.maxConsecutiveSyncFailures, forKey: SyncConfig.consecutiveFailuresKey)

        let context = coreDataStack.newBackgroundContext()
        let plan = await tracker.planHistoryAdvance(hadFailures: true, in: context)

        XCTAssertEqual(
            plan.outcome, .held,
            "hadFailures with an empty deferred set must stall, not silently advance"
        )
    }

    func testBelowThresholdDoesNotAdvanceAndAbandonsNothing() async throws {
        try await recordFailingRuns(SyncConfig.maxConsecutiveSyncFailures - 1, failedIds: ["stuck-1"])

        let context = coreDataStack.newBackgroundContext()
        let plan = await tracker.planHistoryAdvance(hadFailures: true, in: context)
        try await coreDataStack.saveAsync(context: context)

        XCTAssertFalse(plan.shouldAdvance)
        let rows = try await fetchAbandonedRows()
        XCTAssertTrue(
            rows.allSatisfy { $0.state == AbandonedSyncMessage.State.deferred.rawValue },
            "Below the threshold the tracked rows stay deferred — nothing may be abandoned"
        )
        XCTAssertEqual(rows.count, 1, "Tracking itself is durable even while the cursor holds")
        let consecutive = await tracker.consecutiveFailureCount
        XCTAssertEqual(consecutive, SyncConfig.maxConsecutiveSyncFailures - 1)
    }

    // MARK: - Helpers

    private struct AbandonedRow {
        let gmailMessageId: String?
        let state: String?
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
                    state: $0.value(forKey: "state") as? String,
                    reason: $0.value(forKey: "reason") as? String,
                    retryCount: $0.value(forKey: "retryCount") as? Int16 ?? -1
                )
            }
        }
    }
}

private actor SyncPersistenceCancellationGate {
    private var isOpen = false
    private var continuations: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { continuation in
            continuations.append(continuation)
        }
    }

    func open() {
        isOpen = true
        let pendingContinuations = continuations
        continuations.removeAll()
        pendingContinuations.forEach { $0.resume() }
    }
}
