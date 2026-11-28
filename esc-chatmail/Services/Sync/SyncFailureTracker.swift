import Foundation
import CoreData

/// Tracks sync failures and determines when to advance historyId despite failures
///
/// This prevents sync from getting permanently stuck on unfetchable messages
/// by advancing historyId after a configurable number of consecutive failures.
///
/// Failed message IDs are tracked as durable `AbandonedSyncMessage` rows staged
/// into the CALLER's sync context — never saved here — so the tracked set and
/// every ledger transition commit atomically with the history cursor at the
/// run's existing final save. The consecutive-failure counter lives in its own
/// model-v3 SyncCheckpoint row and is supplied explicitly to advancement
/// planning; this actor never increments that counter ahead of a Core Data
/// save. Success-side mutations are applied exclusively through `commit(_:)`
/// after the final save has succeeded.
///
/// Row lifecycle (`AbandonedSyncMessage.state`):
/// - `deferred`: still covered by the frozen cursor; retried by the normal
///   re-scan of the same history window, and therefore excluded from the
///   abandoned-message drain.
/// - `abandoned` (or `nil` on legacy rows): the cursor has advanced past the
///   message; only the drain can recover it.
/// - `exhausted`: the drain gave up on it after `maxAbandonedMessageRetries`
///   message-scoped failures. Kept, never deleted, so the conversation list's
///   banner can say so (`ExhaustedSyncMessagesModel`); it leaves the ledger
///   once a Message with its ID is stored, or when the user's Retry gives it
///   back to the drain (architecture review 2026-11, sync-persist-path#6).
/// `nextRetryAt` paces the drain: stamped with an exponential backoff when a
/// drain attempt fails, so a persistent outage does not burn the bounded
/// retry budget in a handful of back-to-back syncs. A `nil` value (fresh
/// abandonment, legacy rows) is immediately eligible.
actor SyncFailureTracker {
    static let shared = SyncFailureTracker()

    private let defaults: UserDefaults
    private let coreDataStack: CoreDataStack
    private let clock: any SyncClock
    /// The account boundary the banner's read and Retry take their lease from.
    private let syncRunCoordinator: SyncRunCoordinator
    /// Stamps `lastSuccessfulSyncTime`, which history recovery and reconciliation draw
    /// their `after:` floors from. The orchestrator and reconciliation must read the same
    /// source (`ServerTimeSource`).
    private let serverTime: any ServerTimeSource
    private let log = LogCategory.sync.logger

    init(
        defaults: UserDefaults = .standard,
        coreDataStack: CoreDataStack = .shared,
        clock: any SyncClock = SystemSyncClock(),
        serverTime: any ServerTimeSource = ServerClockEstimate.shared,
        syncRunCoordinator: SyncRunCoordinator = .shared
    ) {
        self.defaults = defaults
        self.coreDataStack = coreDataStack
        self.clock = clock
        self.serverTime = serverTime
        self.syncRunCoordinator = syncRunCoordinator
    }

    /// Latched when `recordFailure` could not stage the current failing set
    /// (ledger read failed). While set, the escape hatch must hold: the ledger
    /// does not contain the IDs the cursor would advance past, so abandoning a
    /// stale (or empty) set would lose the unstaged IDs with no durable trace.
    /// Cleared by the next successful
    /// staging or by a committed advance (in-memory only; a relaunch clears it,
    /// and the next failing run re-records the same frozen window).
    private var deferredStagingFailed = false

    // MARK: - Public API

    /// Records a successful sync and resets failure tracking.
    ///
    /// Mutates UserDefaults only — callers inside a sync run must not invoke
    /// this before the run's final save; use `planHistoryAdvance(hadFailures:in:)`
    /// plus `commit(_:)` instead.
    func recordSuccess() {
        recordResolvedProgress(recordsSuccessfulSync: true)
    }

    /// Records this run's complete failing set by reconciling the durable
    /// deferred ledger inside the caller's context WITHOUT saving, so the rows
    /// commit — or die — with the run's final save and can never diverge from
    /// the cursor. The orchestrator stages the separate durable strike count
    /// only after any intermediate save has finished.
    ///
    /// The staged set REPLACES the previous deferred set. The cursor is frozen
    /// while failures persist, so each failing run re-scans the same window and
    /// reports every ID still failing — an ID absent from the latest run either
    /// succeeded or is gone, and keeping its row would let stale IDs accumulate
    /// and be spuriously abandoned by the escape hatch. Never truncate (dropped
    /// IDs would be silently lost when the escape hatch advances); size is
    /// bounded by one sync window's failures.
    ///
    /// - Parameters:
    ///   - fetchFailedIds: IDs whose Gmail fetch failed (blocking).
    ///   - persistenceFailedIds: IDs fetched but not persisted (blocking).
    ///   - sourceHistoryId: The frozen cursor position that produced these IDs,
    ///     recorded on each row so later recovery can bound re-enumeration.
    ///   - context: The sync run's context. Staged only — not saved.
    func recordFailure(
        fetchFailedIds: [String],
        persistenceFailedIds: [String] = [],
        sourceHistoryId: String? = nil,
        in context: NSManagedObjectContext
    ) async {
        var seen = Set<String>()
        var dedupedIds: [String] = []
        var classesById: [String: AbandonedSyncMessage.FailureClass] = [:]
        for id in fetchFailedIds where seen.insert(id).inserted {
            dedupedIds.append(id)
            classesById[id] = .fetchFailed
        }
        for id in persistenceFailedIds where seen.insert(id).inserted {
            dedupedIds.append(id)
            classesById[id] = .persistenceFailed
        }
        guard !dedupedIds.isEmpty else { return }
        let orderedIds = dedupedIds
        let classById = classesById
        let trackedIdSet = seen

        let staged: Bool = await context.perform {
            let trackedAt = Date()
            let request = AbandonedSyncMessage.fetchRequest()
            request.predicate = NSPredicate(
                format: "state == %@ OR gmailMessageId IN %@",
                AbandonedSyncMessage.State.deferred.rawValue,
                orderedIds
            )
            let existing: [AbandonedSyncMessage]
            do {
                existing = try context.fetch(request)
            } catch {
                // Without the existing rows, staging would blind-insert
                // duplicates of rows we could not see (clobbering their drain
                // retryCount at constraint resolution). Skip staging: the
                // cursor stays frozen while failures persist, so the next
                // failing run re-records the same window.
                Log.error("Failed to read failure ledger; skipping deferred staging this run", category: .sync, error: error)
                return false
            }

            var existingByGmailId: [String: AbandonedSyncMessage] = [:]
            for row in existing {
                existingByGmailId[row.gmailMessageId] = row
                // Reconcile: a deferred row absent from this run's failing set
                // recovered (or went gone) on the re-scan — drop it.
                if row.state == AbandonedSyncMessage.State.deferred.rawValue,
                   !trackedIdSet.contains(row.gmailMessageId) {
                    context.delete(row)
                }
            }

            // Upsert the current failing set. retryCount is owned by the
            // abandoned-message drain (stageAbandonedRetryOutcome) and counts
            // drain attempts only; re-tracking must not consume that budget.
            for id in orderedIds {
                let row: AbandonedSyncMessage
                if let existing = existingByGmailId[id] {
                    row = existing
                } else {
                    row = AbandonedSyncMessage(context: context)
                    row.id = UUID()
                    row.gmailMessageId = id
                    row.retryCount = 0
                }
                row.state = AbandonedSyncMessage.State.deferred.rawValue
                row.failureClass = classById[id]?.rawValue
                row.sourceHistoryId = sourceHistoryId
                row.abandonedAt = trackedAt
                // A row re-captured as deferred re-enters the frozen-window
                // lifecycle; any drain pacing from a previous abandonment is
                // void. Without this, a later re-abandonment would hide the
                // row from the drain until the stale backoff elapsed.
                row.nextRetryAt = nil
            }
            return true
        }
        deferredStagingFailed = !staged

        log.warning("Staged \(staged ? orderedIds.count : 0) deferred IDs; the executor owns the durable failure count")
    }

    // MARK: - History Advancement

    /// Decision plus staged ledger transition for one sync run's cursor.
    /// Produced by `planHistoryAdvance(hadFailures:in:)`; hand it back to
    /// `commit(_:)` only after the run's final save has durably committed.
    struct HistoryAdvancePlan: Sendable, Equatable {
        enum Outcome: Sendable, Equatable {
            /// Advance; no failures remain tracked.
            case advancedClean
            /// Advance via the escape hatch; `count` deferred rows were staged
            /// as abandoned in the caller's context.
            case advancedAbandoning(count: Int)
            /// Keep the cursor frozen; tracked rows stay deferred.
            case held
        }

        let outcome: Outcome

        var shouldAdvance: Bool { outcome != .held }

        static let held = HistoryAdvancePlan(outcome: .held)
    }

    /// Determines whether historyId should be advanced despite failures and
    /// stages the matching ledger transition into the caller's context —
    /// without saving and without mutating any success state.
    ///
    /// Advance when:
    /// - There were no failures (normal success case): all deferred rows are
    ///   staged for deletion (the re-scan recovered them).
    /// - Maximum consecutive failures reached (to prevent deadlock): every
    ///   deferred row is staged as `abandoned`, so the skipped IDs and the
    ///   advancing cursor commit in the same save. If that save fails, the
    ///   staged transition dies with the context and the cursor stays frozen —
    ///   advancing without the ledger would discard the only durable record of
    ///   the skipped IDs.
    ///
    /// Apply `commit(_:)` after the final save succeeds; on a failed save,
    /// discard the plan.
    func planHistoryAdvance(
        hadFailures: Bool,
        consecutiveFailureCount: Int,
        in context: NSManagedObjectContext
    ) async -> HistoryAdvancePlan {
        if !hadFailures {
            guard let cleared = await deleteDeferredRows(in: context) else {
                // A clean fetch result does not prove the durable failure
                // ledger is empty. If it cannot be read, advancing would leave
                // deferred rows permanently outside both the frozen history
                // window and the abandoned-message drain.
                log.error("Failed to read failure ledger for clean advance - keeping cursor frozen for retry")
                return .held
            }
            if cleared > 0 {
                log.info("Staged removal of \(cleared) recovered deferred messages")
            }
            return HistoryAdvancePlan(outcome: .advancedClean)
        }

        guard consecutiveFailureCount >= SyncConfig.maxConsecutiveSyncFailures else {
            log.info("Not advancing historyId - \(consecutiveFailureCount) consecutive failures (max: \(SyncConfig.maxConsecutiveSyncFailures))")
            return .held
        }

        guard !deferredStagingFailed else {
            // The current failing set never reached the ledger; the deferred
            // rows on disk (if any) are a stale earlier set. Abandoning them
            // would advance the cursor past the unstaged IDs with no durable
            // trace — hold until a run stages successfully.
            log.error("Escape hatch armed but the current failing set was never staged - keeping cursor frozen for retry")
            return .held
        }

        log.warning("Maximum consecutive failures (\(consecutiveFailureCount)) reached - advancing historyId to prevent deadlock")

        let abandonedCount: Int? = await context.perform {
            let abandonedAt = Date()
            let request = AbandonedSyncMessage.fetchRequest()
            request.predicate = NSPredicate(
                format: "state == %@",
                AbandonedSyncMessage.State.deferred.rawValue
            )
            guard let deferredRows = try? context.fetch(request) else { return nil }
            for row in deferredRows {
                row.state = AbandonedSyncMessage.State.abandoned.rawValue
                row.abandonedAt = abandonedAt
                row.reason = "Max sync failures reached"
                // retryCount untouched: the drain owns it, and re-abandonment
                // must not refresh a partially spent retry budget.
            }
            return deferredRows.count
        }

        guard let abandonedCount else {
            // The ledger could not be read, so advancing would move the cursor
            // past IDs whose only durable record we failed to transition —
            // keep it frozen and retry next run.
            log.error("Failed to read failure ledger for abandonment - keeping cursor frozen for retry")
            return .held
        }

        guard abandonedCount > 0 else {
            // hadFailures means this run recorded blocking IDs, so an empty
            // deferred set here signals a ledger anomaly (e.g. an earlier read
            // failure), not a clean run. Advancing would skip the failing IDs
            // with no durable record — prefer the stall.
            log.error("Escape hatch found no deferred rows to abandon - keeping cursor frozen for retry")
            return .held
        }

        log.warning("Staged abandonment of \(abandonedCount) unfetchable messages")
        return HistoryAdvancePlan(outcome: .advancedAbandoning(count: abandonedCount))
    }

    /// Applies the success-side effects of a plan AFTER the caller's final
    /// save has durably committed the staged ledger rows (and, when advancing,
    /// the cursor). Never call this when the save failed — discarding the plan
    /// leaves every tracker state intact for the retry.
    ///
    /// - Parameter listingStartedAt: For an initial sync or a history
    ///   recovery, when its listing began (`PagedSyncProgress.listingStartedAt`,
    ///   the first attempt's for a resumed run). The last-sync time recorded
    ///   is then no later than it, because the cursor this plan advances to
    ///   was read before it: recovery's window (that time less 10 minutes)
    ///   and reconciliation's (less 5) must reach back to what the listing
    ///   did not see. A resumed run that recorded the time it finished left
    ///   the mail of the days between its attempts to the history from that
    ///   cursor alone, and a recovery after that history expired never
    ///   listed it.
    func commit(
        _ plan: HistoryAdvancePlan,
        recordsSuccessfulSync: Bool = true,
        listingStartedAt: TimeInterval? = nil
    ) async {
        switch plan.outcome {
        case .held:
            return
        case .advancedClean:
            deferredStagingFailed = false
            recordResolvedProgress(
                recordsSuccessfulSync: recordsSuccessfulSync,
                listingStartedAt: listingStartedAt
            )
        case .advancedAbandoning(let count):
            deferredStagingFailed = false
            recordResolvedProgress(
                recordsSuccessfulSync: recordsSuccessfulSync,
                listingStartedAt: listingStartedAt
            )
            // Newly abandoned rows carry their original drain budget, so the
            // drain has work again.
            mayHaveRetryableAbandonedMessages = true
            await MainActor.run {
                NotificationCenter.default.post(
                    name: .syncMessagesAbandoned,
                    object: nil,
                    userInfo: ["count": count]
                )
            }
        }
    }

    /// A clean bounded history slice resolves the same failure state as a
    /// terminal sync, but it must not update the user-facing last-success time
    /// until Gmail's terminal page and Account cursor commit.
    private func recordResolvedProgress(
        recordsSuccessfulSync: Bool,
        listingStartedAt: TimeInterval? = nil
    ) {
        defaults.set(0, forKey: SyncConfig.consecutiveFailuresKey)
        defaults.removeObject(forKey: SyncConfig.persistentFailedIdsKey)
        if recordsSuccessfulSync {
            // The earlier of the device's time and Gmail's: a device clock set ahead
            // stamped a time Gmail had not reached, and the next history recovery,
            // listing `after:` it, skipped the mail between for good.
            let now = serverTime.conservativeNow().timeIntervalSince1970
            // A paged listing's start, never its end (step 8). It was read from the
            // device's clock, so it is moved by the clock's lead as well.
            let syncTime = listingStartedAt.map {
                $0.isFinite ? min(now, $0 - serverTime.deviceClockLead()) : now
            } ?? now
            defaults.set(syncTime, forKey: SyncConfig.lastSuccessfulSyncTimeKey)
            log.debug("Sync success - reset failure tracking")
        } else {
            log.debug("History slice committed - reset failure tracking without recording terminal success")
        }
    }

    /// The Gmail IDs of every `deferred` ledger row, read in the caller's
    /// context. Throws when the ledger cannot be read: an unreadable ledger
    /// is never "empty".
    ///
    /// A clean advance (and `recordFailure`'s reconcile) deletes every
    /// deferred row on the assumption that the run's re-scan listed it. A run
    /// whose list window can start after a deferred message (initial sync's
    /// capped window, recovery's newest-received bound) must re-fetch these
    /// IDs explicitly and fold the outcome into its failures first.
    func deferredMessageIds(in context: NSManagedObjectContext) async throws -> [String] {
        try await context.perform {
            let request = AbandonedSyncMessage.fetchRequest()
            request.predicate = NSPredicate(
                format: "state == %@",
                AbandonedSyncMessage.State.deferred.rawValue
            )
            return try context.fetch(request).map(\.gmailMessageId)
        }
    }

    /// Stages deletion of every deferred row in the caller's context.
    /// - Returns: the number of rows staged for deletion, or `nil` when the
    ///   ledger could not be read.
    private func deleteDeferredRows(in context: NSManagedObjectContext) async -> Int? {
        await context.perform {
            let request = AbandonedSyncMessage.fetchRequest()
            request.predicate = NSPredicate(
                format: "state == %@",
                AbandonedSyncMessage.State.deferred.rawValue
            )
            let rows: [AbandonedSyncMessage]
            do {
                rows = try context.fetch(request)
            } catch {
                return nil
            }
            for row in rows {
                context.delete(row)
            }
            return rows.count
        }
    }

    // MARK: - Query Methods

    /// Returns the timestamp of the last successful sync
    var lastSuccessfulSyncTime: Date? {
        let timestamp = defaults.double(forKey: SyncConfig.lastSuccessfulSyncTimeKey)
        return timestamp > 0 ? Date(timeIntervalSince1970: timestamp) : nil
    }

    /// Returns the number of consecutive sync failures
    var consecutiveFailureCount: Int {
        defaults.integer(forKey: SyncConfig.consecutiveFailuresKey)
    }

    /// Retires pre-v3 account-scoped state after a transaction containing the
    /// durable counter row has saved. A crash before this cleanup is safe: the
    /// row (including a zero tombstone) wins over UserDefaults on the next run.
    func retireLegacyCounterState() {
        defaults.removeObject(forKey: SyncConfig.consecutiveFailuresKey)
        defaults.removeObject(forKey: SyncConfig.persistentFailedIdsKey)
    }

    /// Clears all failure tracking state
    func reset() {
        defaults.set(0, forKey: SyncConfig.consecutiveFailuresKey)
        defaults.removeObject(forKey: SyncConfig.persistentFailedIdsKey)
        log.debug("Failure tracking reset")
    }

    // MARK: - Abandoned Sync Messages

    /// Whether the store may contain retryable abandoned records. `nil` means unknown
    /// (check the store); `false` lets the per-sync drain skip the Core Data fetch in
    /// the common steady state of an empty table. Reset to `nil` by every mutator.
    private var mayHaveRetryableAbandonedMessages: Bool?

    /// Returns abandoned message IDs that are still worth retrying, oldest first.
    /// IDs whose retryCount has reached `SyncConfig.maxAbandonedMessageRetries`
    /// are the exhausted rows, excluded until the user's Retry gives them back
    /// (`retryUndownloadableMessages`), and kept out of the paced count too, or the
    /// skip-the-fetch fast path would never latch once one exists. Deferred rows are excluded: they are still covered
    /// by the frozen cursor, so the normal re-scan of the same history window
    /// already retries them — offering them here would fetch them twice per run.
    func fetchRetryableAbandonedMessageIds(limit: Int = SyncConfig.maxAbandonedMessagesPerSync) async -> [String] {
        if mayHaveRetryableAbandonedMessages == false {
            return []
        }

        await resetLegacyRetryCountsIfNeeded()

        let now = clock.now()
        let context = coreDataStack.newBackgroundContext()
        let outcome: (ids: [String], pacedRowsExist: Bool)? = await context.perform {
            let request = AbandonedSyncMessage.fetchRequest()
            // The nil disjuncts are load-bearing on SQLite: NULL never
            // compares true, so dropping them silently hides legacy rows
            // (state) and fresh abandonments (nextRetryAt).
            request.predicate = NSPredicate(
                format: "retryCount < %d AND (state == nil OR state != %@) AND (nextRetryAt == nil OR nextRetryAt <= %@)",
                SyncConfig.maxAbandonedMessageRetries,
                AbandonedSyncMessage.State.deferred.rawValue,
                now as NSDate
            )
            request.sortDescriptors = [NSSortDescriptor(key: "abandonedAt", ascending: true)]
            request.fetchLimit = limit

            do {
                let ids = try context.fetch(request).map(\.gmailMessageId)
                if !ids.isEmpty {
                    return (ids, false)
                }
                // Distinguish "table is drained" from "rows exist but are
                // paced into the future": only the former may latch the
                // skip-the-fetch fast path, or paced rows would never be
                // offered again once their backoff elapses.
                let pacedRequest = AbandonedSyncMessage.fetchRequest()
                pacedRequest.predicate = NSPredicate(
                    format: "retryCount < %d AND (state == nil OR state != %@)",
                    SyncConfig.maxAbandonedMessageRetries,
                    AbandonedSyncMessage.State.deferred.rawValue
                )
                let pacedCount = try context.count(for: pacedRequest)
                return ([], pacedCount > 0)
            } catch {
                Log.error("Failed to fetch retryable abandoned sync messages", category: .sync, error: error)
                return nil
            }
        }

        // Only cache on a successful fetch — an error must not latch "empty",
        // and neither may an empty result that only reflects pacing.
        if let outcome {
            if !outcome.ids.isEmpty {
                mayHaveRetryableAbandonedMessages = true
            } else {
                mayHaveRetryableAbandonedMessages = outcome.pacedRowsExist ? nil : false
            }
        }
        return outcome?.ids ?? []
    }

    /// One-time reset of retryCount on records written before the retry drain
    /// existed: the old code incremented retryCount on every re-abandonment, so a
    /// legacy record could sit at or above the drain's cap without a single drain
    /// attempt having run — permanently hidden by the `retryCount <` predicate.
    private func resetLegacyRetryCountsIfNeeded() async {
        guard !defaults.bool(forKey: SyncConfig.abandonedRetryCountResetKey) else { return }

        let context = coreDataStack.newBackgroundContext()
        let didReset: Bool = await context.perform {
            let request = AbandonedSyncMessage.fetchRequest()
            // Never a row the drain itself gave up on: its count is the drain's.
            // Only a build that drained rows writes that state, and it runs this
            // reset first, so the term is a guard, not a migration.
            request.predicate = NSPredicate(
                format: "retryCount > 0 AND (state == nil OR state != %@)",
                AbandonedSyncMessage.State.exhausted.rawValue
            )

            do {
                let records = try context.fetch(request)
                for record in records {
                    record.retryCount = 0
                }
                if context.hasChanges {
                    try context.save()
                    Log.info("Reset legacy retryCount on \(records.count) abandoned messages", category: .sync)
                }
                return true
            } catch {
                Log.error("Failed to reset legacy abandoned retry counts", category: .sync, error: error)
                return false
            }
        }

        if didReset {
            defaults.set(true, forKey: SyncConfig.abandonedRetryCountResetKey)
        }
    }

    /// Stages the outcome of an abandoned-message retry pass into the caller's
    /// context WITHOUT saving, so ledger resolution commits atomically with the
    /// recovered messages at the run's next save: recovered and
    /// server-side-deleted messages are removed from tracking.
    ///
    /// Only a message-scoped failure (`failedIds`: a 4xx, an undecodable or
    /// unprocessable payload, a failed persist, a transport error
    /// `MessageFetcher.isRetriableError` does not name) spends the row's retryCount. A
    /// row whose count reaches `SyncConfig.maxAbandonedMessageRetries` becomes
    /// `exhausted`, kept with the count at the cap: the drain's `retryCount <`
    /// term excludes it, and the conversation list's banner counts it. It was
    /// deleted, with only a log line, until 2026-11 (sync-persist-path#6).
    ///
    /// A transient failure (`transientlyFailedIds`: a timeout, a dropped or
    /// refused connection, a 5xx, a 429) says nothing about the message: it
    /// spends nothing, so an outage no longer exhausts the rows it meets, and
    /// it waits as long as the row has been abandoned
    /// (`transientRetryBackoffInterval`), so a message that always fails this
    /// way is asked about less and less often, twice a day at most after its
    /// first day, and is never exhausted: after
    /// `SyncConfig.abandonedMessageStalledAge` the banner counts it
    /// (`AbandonedSyncMessage.undownloadablePredicate(now:)`). If the save
    /// later fails, the staged changes die with the context and every record
    /// stays for the next drain.
    func stageAbandonedRetryOutcome(
        recoveredIds: [String],
        goneIds: [String],
        failedIds: [String],
        transientlyFailedIds: [String] = [],
        in context: NSManagedObjectContext
    ) async {
        let resolvedIds = recoveredIds + goneIds
        guard !resolvedIds.isEmpty || !failedIds.isEmpty || !transientlyFailedIds.isEmpty else { return }

        if !recoveredIds.isEmpty {
            log.info("Recovered \(recoveredIds.count) previously abandoned messages")
        }
        if !goneIds.isEmpty {
            log.info("Dropping \(goneIds.count) abandoned messages deleted server-side")
        }

        mayHaveRetryableAbandonedMessages = nil

        let now = clock.now()
        await context.perform {
            let request = AbandonedSyncMessage.fetchRequest()
            request.predicate = NSPredicate(
                format: "gmailMessageId IN %@",
                resolvedIds + failedIds + transientlyFailedIds
            )

            do {
                let resolvedSet = Set(resolvedIds)
                let failedSet = Set(failedIds)
                let cap = Int16(clamping: SyncConfig.maxAbandonedMessageRetries)
                for record in try context.fetch(request) {
                    if resolvedSet.contains(record.gmailMessageId) {
                        context.delete(record)
                    } else if failedSet.contains(record.gmailMessageId) {
                        let retryCount = record.retryCount + 1
                        if retryCount >= cap {
                            Log.warning("Giving up on abandoned message \(Log.hashIdentifier(record.gmailMessageId)) after \(retryCount) retries; kept as exhausted", category: .sync)
                            record.retryCount = cap
                            record.state = AbandonedSyncMessage.State.exhausted.rawValue
                            record.reason = "Drain retries exhausted"
                            record.nextRetryAt = nil
                        } else {
                            record.retryCount = retryCount
                            // Pace the next attempt: without a backoff, a
                            // persistent outage burns the whole bounded
                            // budget across a handful of back-to-back syncs.
                            record.nextRetryAt = now.addingTimeInterval(
                                Self.retryBackoffInterval(forRetryCount: Int(retryCount))
                            )
                        }
                    } else {
                        // Transient: no attempt spent, and a wait that grows
                        // with the row's age. A fixed wait asked every 15
                        // minutes, for good, about a message that always fails.
                        record.nextRetryAt = now.addingTimeInterval(
                            Self.transientRetryBackoffInterval(
                                abandonedAt: record.abandonedAt,
                                retryCount: Int(record.retryCount),
                                now: now
                            )
                        )
                    }
                }
            } catch {
                Log.error("Failed to stage abandoned retry outcome", category: .sync, error: error)
            }
        }
    }

    // MARK: - Exhausted Sync Messages

    /// Stages, in the run's context, the removal of every exhausted row whose
    /// message is now stored (by this run, staged in the same context and not
    /// yet saved, or by an earlier one: the missed-message check, a history
    /// recovery's listing, a re-scan). The row's mail is in the app, if not
    /// always its latest update (a stored row whose later update failed counts
    /// as stored), so the banner no longer counts it. Commits with the run's
    /// save or dies with it. A ledger or message read that fails removes
    /// nothing. A stalled row is left to the drain, which deletes it when it
    /// stores the message.
    ///
    /// - Returns: how many rows were staged for removal, or nil when a read failed.
    @discardableResult
    func stageClearingStoredExhaustedMessages(in context: NSManagedObjectContext) async -> Int? {
        await context.perform {
            do {
                let request = AbandonedSyncMessage.fetchRequest()
                request.predicate = AbandonedSyncMessage.exhaustedPredicate
                let rows = try context.fetch(request)
                guard !rows.isEmpty else { return 0 }
                // An object fetch, never a dictionary one: a dictionary result
                // ignores the context's unsaved inserts, so a message this run
                // stored was seen one run late.
                let messageRequest = Message.fetchRequest()
                messageRequest.predicate = NSPredicate(format: "id IN %@", rows.map(\.gmailMessageId))
                messageRequest.includesPendingChanges = true
                let storedIds = Set(try context.fetch(messageRequest).map(\.id))
                var cleared = 0
                for row in rows where storedIds.contains(row.gmailMessageId) {
                    context.delete(row)
                    cleared += 1
                }
                return cleared
            } catch {
                Log.error("Failed to read exhausted sync messages; leaving them", category: .sync, error: error)
                return nil
            }
        }
    }

    /// The Gmail IDs of every row the banner counts (exhausted or stalled,
    /// `AbandonedSyncMessage.undownloadablePredicate(now:)`), oldest first,
    /// read under the account-work lease (`ExhaustedSyncMessagesManaging`).
    func fetchUndownloadableMessageIds() async -> [String]? {
        let now = clock.now()
        return await withAccountWorkLease { (_: SyncRun) async -> [String]? in
            let context = self.coreDataStack.newBackgroundContext()
            return await context.perform {
                let request = AbandonedSyncMessage.fetchRequest()
                request.predicate = AbandonedSyncMessage.undownloadablePredicate(now: now)
                request.sortDescriptors = [NSSortDescriptor(key: "abandonedAt", ascending: true)]
                do {
                    return try context.fetch(request).map(\.gmailMessageId)
                } catch {
                    Log.error("Failed to read exhausted sync messages", category: .sync, error: error)
                    return nil
                }
            }
        } ?? nil
    }

    /// Gives every row the banner counts back to the drain: `abandoned`, its
    /// retry count spent nothing, due now. `abandonedAt` is left as it was: the
    /// delivery-unknown probe reads it as when the row was recorded
    /// (`DeliveryUnknownResolution.storeAgreesItWasNotSent`), and a stalled row
    /// that fails again is counted again at once. Written on a context of its own and saved
    /// under the account-work lease, never the exclusive run: a lease holder
    /// never waits behind a sync, and the lease keeps the write inside the
    /// account boundary (teardown drains it before the store is reset). A sync
    /// run saving the same row after this wins its own changed properties
    /// (`NSMergeByPropertyObjectTrumpMergePolicy`), so a row the run had just
    /// exhausted again stays exhausted and the banner shows it again.
    func retryUndownloadableMessages() async -> ExhaustedSyncMessagesRetryOutcome {
        let now = clock.now()
        let outcome: ExhaustedSyncMessagesRetryOutcome = await withAccountWorkLease {
            (lease: SyncRun) async -> ExhaustedSyncMessagesRetryOutcome in
            let context = self.coreDataStack.newBackgroundContext()
            let coordinator = self.syncRunCoordinator
            // A read that fails is a failed Retry, never nothing to give back:
            // the banner was hidden for the Retry and must come back.
            let givenBack: Int? = await context.perform {
                let request = AbandonedSyncMessage.fetchRequest()
                request.predicate = AbandonedSyncMessage.undownloadablePredicate(now: now)
                do {
                    let rows = try context.fetch(request)
                    for row in rows {
                        row.state = AbandonedSyncMessage.State.abandoned.rawValue
                        row.retryCount = 0
                        row.nextRetryAt = nil
                        row.reason = "Retried by the user"
                    }
                    return rows.count
                } catch {
                    Log.error("Failed to read sync messages to give back", category: .sync, error: error)
                    return nil
                }
            }
            guard let givenBack else { return .failed }
            guard givenBack > 0 else { return .nothingToGiveBack }
            guard await coordinator.isActiveRun(lease) else { return .failed }
            return await context.perform {
                do {
                    try context.save()
                    Log.info("Gave \(givenBack) undownloaded sync messages back to the drain", category: .sync)
                    return .gaveBack
                } catch {
                    Log.error("Failed to give undownloaded sync messages back", category: .sync, error: error)
                    return .failed
                }
            }
        } ?? .failed
        if outcome == .gaveBack {
            mayHaveRetryableAbandonedMessages = true
        }
        return outcome
    }

    /// Runs `operation` under a non-exclusive account-work lease, or answers
    /// nil while no account work is admitted (an account transition).
    private func withAccountWorkLease<Result: Sendable>(
        _ operation: (SyncRun) async -> Result
    ) async -> Result? {
        guard let request = await syncRunCoordinator.makeAccountWorkRequest(),
              let lease = await syncRunCoordinator.acquireAccountWorkLease(
                kind: .foregroundIncremental,
                for: request
              ) else {
            return nil
        }
        let result = await operation(lease)
        await syncRunCoordinator.endRun(lease)
        return result
    }

    /// Exponential drain backoff: 15 min after the first failed attempt,
    /// quadrupling per attempt, capped at 12 hours. Fresh abandonments carry
    /// `nextRetryAt == nil` and stay immediately eligible — pacing starts
    /// only after a drain attempt has actually failed.
    nonisolated static func retryBackoffInterval(forRetryCount retryCount: Int) -> TimeInterval {
        let exponent = max(0, retryCount - 1)
        let interval = SyncConfig.abandonedRetryBackoffBase * pow(4, Double(exponent))
        return min(interval, SyncConfig.abandonedRetryBackoffCap)
    }

    /// The wait after a transient drain failure, which spends no retry: as
    /// long as the row has been abandoned, from the base backoff (15 minutes)
    /// to its cap (12 hours), and never less than the next spent attempt would
    /// wait. Each failure thereby roughly doubles the time since abandonment
    /// (15 min, 30, 1 h, 2 h ... then every 12 h), where a fixed wait asked
    /// about a message that always fails every 15 minutes for good. A clock
    /// behind `abandonedAt` reads as a fresh row and waits the base.
    nonisolated static func transientRetryBackoffInterval(
        abandonedAt: Date,
        retryCount: Int,
        now: Date
    ) -> TimeInterval {
        let age = now.timeIntervalSince(abandonedAt)
        let ageWait = age.isFinite
            ? min(max(age, SyncConfig.abandonedRetryBackoffBase), SyncConfig.abandonedRetryBackoffCap)
            : SyncConfig.abandonedRetryBackoffBase
        return max(ageWait, retryBackoffInterval(forRetryCount: retryCount + 1))
    }
}
