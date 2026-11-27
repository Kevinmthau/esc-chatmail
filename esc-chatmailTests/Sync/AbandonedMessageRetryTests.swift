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
    private var syncRunCoordinator: SyncRunCoordinator!
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
        // A coordinator of the suite's own: the banner's read and Retry take a
        // lease from it, and the quiescence test closes it.
        syncRunCoordinator = SyncRunCoordinator()
        sut = SyncFailureTracker(
            defaults: defaults,
            coreDataStack: coreDataStack,
            clock: clock,
            syncRunCoordinator: syncRunCoordinator
        )
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
        sut = nil
        syncRunCoordinator = nil
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
    private func applyRetryOutcome(
        recoveredIds: [String],
        goneIds: [String],
        failedIds: [String],
        transientlyFailedIds: [String] = []
    ) async throws {
        let context = coreDataStack.newBackgroundContext()
        await sut.stageAbandonedRetryOutcome(
            recoveredIds: recoveredIds,
            goneIds: goneIds,
            failedIds: failedIds,
            transientlyFailedIds: transientlyFailedIds,
            in: context
        )
        try await coreDataStack.saveAsync(context: context)
    }

    private func storedState(id: String) async throws -> String? {
        let context = coreDataStack.newBackgroundContext()
        return try await context.perform {
            let request = NSFetchRequest<AbandonedSyncMessage>(entityName: "AbandonedSyncMessage")
            request.predicate = NSPredicate(format: "gmailMessageId == %@", id)
            return try context.fetch(request).first?.value(forKey: "state") as? String
        }
    }

    private func seedStoredMessage(id: String) async throws {
        let context = coreDataStack.newBackgroundContext()
        try await context.perform {
            _ = MessageBuilder().withId(id).build(in: context)
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

    /// Composite lifecycle pin: an abandoned row paced into the future can be
    /// re-captured as deferred (its id reappears in a failing window) and
    /// later re-abandoned by the escape hatch. The deferred capture must void
    /// the stale pacing, or the freshly re-abandoned row would hide from the
    /// drain until the residual backoff elapsed.
    func testReabandonedRowIsImmediatelyEligibleAfterDeferredRoundTrip() async throws {
        try await seedAbandonedMessage(
            id: "round-trip",
            retryCount: 1,
            nextRetryAt: clock.now().addingTimeInterval(SyncConfig.abandonedRetryBackoffCap)
        )
        defaults.set(SyncConfig.maxConsecutiveSyncFailures - 1, forKey: SyncConfig.consecutiveFailuresKey)

        let context = coreDataStack.newBackgroundContext()
        await sut.recordFailure(fetchFailedIds: ["round-trip"], in: context)
        let plan = await sut.planHistoryAdvance(
            hadFailures: true,
            consecutiveFailureCount: SyncConfig.maxConsecutiveSyncFailures,
            in: context
        )
        XCTAssertTrue(plan.shouldAdvance, "The seeded counter must arm the escape hatch")
        try await coreDataStack.saveAsync(context: context)
        await sut.commit(plan)

        let ids = await sut.fetchRetryableAbandonedMessageIds()
        XCTAssertEqual(
            ids, ["round-trip"],
            "A re-abandoned row must be immediately drain-eligible; stale pacing must not survive the deferred round-trip"
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

    /// The drain gives up on a row after its last message-scoped failure and
    /// keeps it, exhausted, rather than deleting it with only a log line
    /// (architecture review 2026-11, sync-persist-path#6). Until then this test
    /// pinned the deletion.
    ///
    /// Revert-check: the exhausted branch of `SyncFailureTracker.stageAbandonedRetryOutcome`
    /// set back to `context.delete(record)`. The row is then gone and the
    /// exhausted count empty.
    func testRecordOutcome_failureExhaustsAfterMaxRetries_keepingTheRow() async throws {
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
        XCTAssertEqual(records.map(\.id), ["flaky"], "The row is kept, for the banner")
        XCTAssertEqual(records.first?.retryCount, Int16(SyncConfig.maxAbandonedMessageRetries))
        let state = try await storedState(id: "flaky")
        XCTAssertEqual(state, AbandonedSyncMessage.State.exhausted.rawValue)
        let exhausted = await sut.fetchExhaustedMessageIds()
        XCTAssertEqual(exhausted, ["flaky"], "The banner counts it")
    }

    /// Revert-check: as above, the exhausted branch set back to a delete.
    func testRecordOutcome_failureReachingCap_keepsTheRowExhaustedAtTheCap() async throws {
        try await seedAbandonedMessage(id: "last-chance", retryCount: Int16(SyncConfig.maxAbandonedMessageRetries - 1))

        try await applyRetryOutcome(recoveredIds: [], goneIds: [], failedIds: ["last-chance"])

        let records = try await storedRecords()
        XCTAssertEqual(records.map(\.id), ["last-chance"])
        XCTAssertEqual(records.first?.retryCount, Int16(SyncConfig.maxAbandonedMessageRetries))
        let state = try await storedState(id: "last-chance")
        XCTAssertEqual(state, AbandonedSyncMessage.State.exhausted.rawValue)
        let nextRetryAt = try await storedNextRetryAt(id: "last-chance")
        XCTAssertNil(nextRetryAt, "An exhausted row waits for nothing but a Retry")
    }

    /// A timeout, a network error, a 5xx or a 429 says nothing about the
    /// message: the row waits as a spent attempt would and spends nothing, so
    /// an outage that meets the drain does not exhaust its rows.
    ///
    /// Revert-check: the transient branch of `stageAbandonedRetryOutcome`
    /// (the final `else`) spending `retryCount` like a failure.
    func testRecordOutcome_transientFailure_stampsTheBackoffWithoutSpendingARetry() async throws {
        try await seedAbandonedMessage(id: "transient", retryCount: 2)

        try await applyRetryOutcome(
            recoveredIds: [],
            goneIds: [],
            failedIds: [],
            transientlyFailedIds: ["transient"]
        )

        let records = try await storedRecords()
        XCTAssertEqual(records.first?.retryCount, 2)
        let stamped = try await storedNextRetryAt(id: "transient")
        XCTAssertEqual(
            stamped,
            clock.now().addingTimeInterval(SyncFailureTracker.retryBackoffInterval(forRetryCount: 3))
        )
        let ids = await sut.fetchRetryableAbandonedMessageIds()
        XCTAssertEqual(ids, [], "It waits out the backoff")
    }

    // MARK: - Exhausted rows

    /// The banner counts the rows the drain gave up on by their retry count,
    /// not their state: a row re-abandoned at the cap counts, and so does a
    /// legacy row with no state. A deferred row at the cap is the frozen
    /// cursor's again, and a row below the cap is still the drain's.
    ///
    /// Revert-check: `AbandonedSyncMessage.exhaustedPredicate` set to
    /// `state == "exhausted"` misses the re-abandoned and legacy rows; its
    /// `state == nil` disjunct dropped misses the legacy row (SQLite).
    func testFetchExhaustedMessageIds_countsRowsAtTheCapThatAreNotDeferred_oldestFirst() async throws {
        let cap = Int16(SyncConfig.maxAbandonedMessageRetries)
        try await seedAbandonedMessage(
            id: "exhausted", retryCount: cap, abandonedAt: Date(timeIntervalSinceNow: -300),
            state: AbandonedSyncMessage.State.exhausted.rawValue
        )
        try await seedAbandonedMessage(
            id: "reabandoned", retryCount: cap, abandonedAt: Date(timeIntervalSinceNow: -200),
            state: AbandonedSyncMessage.State.abandoned.rawValue
        )
        try await seedAbandonedMessage(
            id: "legacy", retryCount: cap, abandonedAt: Date(timeIntervalSinceNow: -100), state: nil
        )
        try await seedAbandonedMessage(
            id: "deferred", retryCount: cap, state: AbandonedSyncMessage.State.deferred.rawValue
        )
        try await seedAbandonedMessage(
            id: "still-draining", retryCount: cap - 1, state: AbandonedSyncMessage.State.abandoned.rawValue
        )

        let ids = await sut.fetchExhaustedMessageIds()

        XCTAssertEqual(ids, ["exhausted", "reabandoned", "legacy"])
    }

    /// An exhausted row stays out of the drain, as earlier builds' `retryCount <`
    /// term keeps it out too, and out of the paced count, so the drain's
    /// skip-the-fetch fast path still latches over it.
    func testFetchRetryable_excludesExhaustedRows() async throws {
        try await seedAbandonedMessage(
            id: "exhausted",
            retryCount: Int16(SyncConfig.maxAbandonedMessageRetries),
            state: AbandonedSyncMessage.State.exhausted.rawValue
        )

        let ids = await sut.fetchRetryableAbandonedMessageIds()

        XCTAssertEqual(ids, [])
    }

    /// A row whose message is now stored leaves the ledger, staged in the
    /// caller's context; one whose message is not stays.
    ///
    /// Revert-check: the `storedIds.contains` filter in
    /// `SyncFailureTracker.stageClearingStoredExhaustedMessages` dropped. The
    /// row whose message is still missing is then removed too.
    func testStageClearingStoredExhaustedMessages_removesOnlyRowsWhoseMessageIsStored() async throws {
        let cap = Int16(SyncConfig.maxAbandonedMessageRetries)
        try await seedAbandonedMessage(id: "now-stored", retryCount: cap, state: AbandonedSyncMessage.State.exhausted.rawValue)
        try await seedAbandonedMessage(id: "still-missing", retryCount: cap, state: AbandonedSyncMessage.State.exhausted.rawValue)
        try await seedStoredMessage(id: "now-stored")

        let context = coreDataStack.newBackgroundContext()
        let cleared = await sut.stageClearingStoredExhaustedMessages(in: context)
        let beforeSave = try await storedRecords()
        XCTAssertEqual(beforeSave.count, 2, "Staged only: the caller's save commits it")
        try await coreDataStack.saveAsync(context: context)

        XCTAssertEqual(cleared, 1)
        let records = try await storedRecords()
        XCTAssertEqual(records.map(\.id), ["still-missing"])
    }

    /// Retry gives the rows back to the drain, which offers them again even
    /// after it had latched its empty fast path over them.
    ///
    /// Revert-check: `mayHaveRetryableAbandonedMessages = true` in
    /// `SyncFailureTracker.retryExhaustedMessages` removed. The drain then
    /// keeps answering from its latch and never offers the row.
    func testRetryExhaustedMessages_givesTheRowsBackToTheDrain() async throws {
        try await seedAbandonedMessage(
            id: "given-back",
            retryCount: Int16(SyncConfig.maxAbandonedMessageRetries),
            state: AbandonedSyncMessage.State.exhausted.rawValue
        )
        let latched = await sut.fetchRetryableAbandonedMessageIds()
        XCTAssertEqual(latched, [], "Positive control: the drain sees nothing to retry and latches")

        let gaveBack = await sut.retryExhaustedMessages()

        XCTAssertTrue(gaveBack)
        let ids = await sut.fetchRetryableAbandonedMessageIds()
        XCTAssertEqual(ids, ["given-back"])
        let records = try await storedRecords()
        XCTAssertEqual(records.first?.retryCount, 0, "It has its whole budget again")
        let exhausted = await sut.fetchExhaustedMessageIds()
        XCTAssertEqual(exhausted, [])
    }

    /// A Retry asked for while an account transition owns the boundary writes
    /// nothing: the lease is refused, so the old account's rows are never
    /// rewritten into a store about to be reset. Nor is the banner's read
    /// answered as an empty ledger.
    ///
    /// HONEST SCOPE: no one-line revert both drops the lease and compiles
    /// (`withAccountWorkLease` needs the lease to call its operation). This
    /// pins the refusal.
    func testRetryExhaustedMessages_duringAnAccountTransition_changesNothing() async throws {
        try await seedAbandonedMessage(
            id: "exhausted",
            retryCount: Int16(SyncConfig.maxAbandonedMessageRetries),
            state: AbandonedSyncMessage.State.exhausted.rawValue
        )
        await syncRunCoordinator.beginQuiescence()

        let gaveBack = await sut.retryExhaustedMessages()
        let read = await sut.fetchExhaustedMessageIds()
        await syncRunCoordinator.endQuiescence()

        XCTAssertFalse(gaveBack)
        XCTAssertNil(read, "No answer is not an empty ledger")
        let state = try await storedState(id: "exhausted")
        XCTAssertEqual(state, AbandonedSyncMessage.State.exhausted.rawValue)
    }

    /// The one-time reset of pre-drain retry counts leaves the drain's own
    /// verdicts alone.
    ///
    /// Revert-check: the `state != "exhausted"` term in
    /// `SyncFailureTracker.resetLegacyRetryCountsIfNeeded`.
    func testLegacyRetryCountReset_leavesExhaustedRowsAlone() async throws {
        defaults.set(false, forKey: SyncConfig.abandonedRetryCountResetKey)
        try await seedAbandonedMessage(
            id: "exhausted",
            retryCount: Int16(SyncConfig.maxAbandonedMessageRetries),
            state: AbandonedSyncMessage.State.exhausted.rawValue
        )
        try await seedAbandonedMessage(id: "legacy", retryCount: Int16(SyncConfig.maxAbandonedMessageRetries + 2))

        let ids = await sut.fetchRetryableAbandonedMessageIds()

        XCTAssertEqual(ids, ["legacy"])
        let exhausted = await sut.fetchExhaustedMessageIds()
        XCTAssertEqual(exhausted, ["exhausted"])
    }

    func testRecordOutcome_allEmpty_isNoOp() async throws {
        try await seedAbandonedMessage(id: "kept")

        try await applyRetryOutcome(recoveredIds: [], goneIds: [], failedIds: [])

        let records = try await storedRecords()
        XCTAssertEqual(records.map(\.id), ["kept"])
    }
}
