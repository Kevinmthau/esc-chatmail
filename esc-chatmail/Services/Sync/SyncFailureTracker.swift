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
/// run's existing final save. UserDefaults holds only the consecutive-failure
/// counter and the last-success timestamp; success-side mutations are applied
/// exclusively through `commit(_:)` after the final save has succeeded.
///
/// Row lifecycle (`AbandonedSyncMessage.state`):
/// - `deferred`: still covered by the frozen cursor; retried by the normal
///   re-scan of the same history window, and therefore excluded from the
///   abandoned-message drain.
/// - `abandoned` (or `nil` on legacy rows): the cursor has advanced past the
///   message; only the drain can recover it.
/// `nextRetryAt` stays unconsumed here — retry pacing belongs to the resumable
/// executor work.
actor SyncFailureTracker {
    static let shared = SyncFailureTracker()

    private let defaults: UserDefaults
    private let coreDataStack: CoreDataStack
    private let log = LogCategory.sync.logger

    init(defaults: UserDefaults = .standard, coreDataStack: CoreDataStack = .shared) {
        self.defaults = defaults
        self.coreDataStack = coreDataStack
    }

    // MARK: - Public API

    /// Records a successful sync and resets failure tracking.
    ///
    /// Mutates UserDefaults only — callers inside a sync run must not invoke
    /// this before the run's final save; use `planHistoryAdvance(hadFailures:in:)`
    /// plus `commit(_:)` instead.
    func recordSuccess() {
        defaults.set(0, forKey: SyncConfig.consecutiveFailuresKey)
        // Legacy cleanup: tracked IDs lived under this key before they moved
        // into durable AbandonedSyncMessage rows.
        defaults.removeObject(forKey: SyncConfig.persistentFailedIdsKey)
        defaults.set(Date().timeIntervalSince1970, forKey: SyncConfig.lastSuccessfulSyncTimeKey)
        log.debug("Sync success - reset failure tracking")
    }

    /// Records this run's complete failing set: increments the consecutive
    /// failure counter and reconciles the durable deferred ledger inside the
    /// caller's context WITHOUT saving, so the rows commit — or die — with the
    /// run's final save and can never diverge from the cursor.
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

        // The counter increments immediately (not post-save) so the escape
        // hatch can fire in the same run that reaches the threshold. A run
        // whose final save later fails leaves the counter one high — a
        // conservative error: the hatch may arm one run early, and the set it
        // abandons is always the current run's staged rows.
        let consecutiveFailures = defaults.integer(forKey: SyncConfig.consecutiveFailuresKey) + 1
        defaults.set(consecutiveFailures, forKey: SyncConfig.consecutiveFailuresKey)

        await context.perform {
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
                return
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
            }
        }

        log.warning("Consecutive failures: \(consecutiveFailures)/\(SyncConfig.maxConsecutiveSyncFailures), staged \(orderedIds.count) deferred IDs")
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
        in context: NSManagedObjectContext
    ) async -> HistoryAdvancePlan {
        if !hadFailures {
            let cleared = await deleteDeferredRows(in: context)
            if cleared > 0 {
                log.info("Staged removal of \(cleared) recovered deferred messages")
            }
            return HistoryAdvancePlan(outcome: .advancedClean)
        }

        let consecutiveFailures = defaults.integer(forKey: SyncConfig.consecutiveFailuresKey)

        guard consecutiveFailures >= SyncConfig.maxConsecutiveSyncFailures else {
            log.info("Not advancing historyId - \(consecutiveFailures) consecutive failures (max: \(SyncConfig.maxConsecutiveSyncFailures))")
            return .held
        }

        log.warning("Maximum consecutive failures (\(consecutiveFailures)) reached - advancing historyId to prevent deadlock")

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
            // Nothing tracked (failures without recorded IDs) — a plain advance.
            return HistoryAdvancePlan(outcome: .advancedClean)
        }

        log.warning("Staged abandonment of \(abandonedCount) unfetchable messages")
        return HistoryAdvancePlan(outcome: .advancedAbandoning(count: abandonedCount))
    }

    /// Applies the success-side effects of a plan AFTER the caller's final
    /// save has durably committed the staged ledger rows (and, when advancing,
    /// the cursor). Never call this when the save failed — discarding the plan
    /// leaves every tracker state intact for the retry.
    func commit(_ plan: HistoryAdvancePlan) async {
        switch plan.outcome {
        case .held:
            return
        case .advancedClean:
            recordSuccess()
        case .advancedAbandoning(let count):
            recordSuccess()
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

    /// Stages deletion of every deferred row in the caller's context.
    /// - Returns: the number of rows staged for deletion.
    private func deleteDeferredRows(in context: NSManagedObjectContext) async -> Int {
        await context.perform {
            let request = AbandonedSyncMessage.fetchRequest()
            request.predicate = NSPredicate(
                format: "state == %@",
                AbandonedSyncMessage.State.deferred.rawValue
            )
            let rows = (try? context.fetch(request)) ?? []
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
    /// IDs whose retryCount has reached `SyncConfig.maxAbandonedMessageRetries` are
    /// excluded permanently. Deferred rows are excluded: they are still covered
    /// by the frozen cursor, so the normal re-scan of the same history window
    /// already retries them — offering them here would fetch them twice per run.
    func fetchRetryableAbandonedMessageIds(limit: Int = SyncConfig.maxAbandonedMessagesPerSync) async -> [String] {
        if mayHaveRetryableAbandonedMessages == false {
            return []
        }

        await resetLegacyRetryCountsIfNeeded()

        let context = coreDataStack.newBackgroundContext()
        let ids: [String]? = await context.perform {
            let request = AbandonedSyncMessage.fetchRequest()
            request.predicate = NSPredicate(
                format: "retryCount < %d AND (state == nil OR state != %@)",
                SyncConfig.maxAbandonedMessageRetries,
                AbandonedSyncMessage.State.deferred.rawValue
            )
            request.sortDescriptors = [NSSortDescriptor(key: "abandonedAt", ascending: true)]
            request.fetchLimit = limit

            do {
                return try context.fetch(request).map(\.gmailMessageId)
            } catch {
                Log.error("Failed to fetch retryable abandoned sync messages", category: .sync, error: error)
                return nil
            }
        }

        // Only cache on a successful fetch — an error must not latch "empty".
        if let ids {
            mayHaveRetryableAbandonedMessages = !ids.isEmpty
        }
        return ids ?? []
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
            request.predicate = NSPredicate(format: "retryCount > 0")

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
    /// server-side-deleted messages are removed from tracking; transient
    /// failures have their retryCount incremented. Records whose retryCount
    /// reaches `SyncConfig.maxAbandonedMessageRetries` are deleted — they would
    /// never be offered again, and keeping them would grow the table without
    /// bound. If the save later fails, the staged changes die with the context
    /// and every record stays for the next drain.
    func stageAbandonedRetryOutcome(
        recoveredIds: [String],
        goneIds: [String],
        failedIds: [String],
        in context: NSManagedObjectContext
    ) async {
        let resolvedIds = recoveredIds + goneIds
        guard !resolvedIds.isEmpty || !failedIds.isEmpty else { return }

        if !recoveredIds.isEmpty {
            log.info("Recovered \(recoveredIds.count) previously abandoned messages")
        }
        if !goneIds.isEmpty {
            log.info("Dropping \(goneIds.count) abandoned messages deleted server-side")
        }

        mayHaveRetryableAbandonedMessages = nil

        await context.perform {
            let request = AbandonedSyncMessage.fetchRequest()
            request.predicate = NSPredicate(format: "gmailMessageId IN %@", resolvedIds + failedIds)

            do {
                let resolvedSet = Set(resolvedIds)
                for record in try context.fetch(request) {
                    if resolvedSet.contains(record.gmailMessageId) {
                        context.delete(record)
                    } else {
                        let retryCount = record.retryCount + 1
                        if retryCount >= SyncConfig.maxAbandonedMessageRetries {
                            Log.warning("Giving up on abandoned message \(record.gmailMessageId) after \(retryCount) retries", category: .sync)
                            context.delete(record)
                        } else {
                            record.retryCount = retryCount
                        }
                    }
                }
            } catch {
                Log.error("Failed to stage abandoned retry outcome", category: .sync, error: error)
            }
        }
    }
}
