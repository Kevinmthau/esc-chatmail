import Foundation

/// The escape hatch's strikes as a run reads and stages them: how many
/// failing runs in a row held the cursor, and when the last of them counted.
/// Kept in the `syncFailureCounter.v1` row (`SyncFailureCounterCheckpointStore`),
/// staged in the run's context with the ledger and the cursor.
struct SyncFailureStrikes: Equatable, Sendable {
    let count: Int
    /// When the last strike counted. Nil where none has since the counter was
    /// last reset, and on every row an earlier build wrote.
    let lastStrikeAt: Date?

    static let cleared = SyncFailureStrikes(count: 0, lastStrikeAt: nil)
}

/// When a run that held the cursor spends one of the escape hatch's
/// `SyncConfig.maxConsecutiveSyncFailures` strikes (architecture review
/// 2026-11, sync-engine#2).
///
/// A held foreground run used to be followed at once by up to three forced
/// runs, so one burst of 429s, 5xx or timeouts spent all three strikes within
/// seconds and sent the run's IDs to the abandoned drain, which retries on an
/// hours-long schedule. The slice path now counts a strike only once
/// `SyncConfig.minimumSyncFailureStrikeSpacing` has passed since the last one.
///
/// Three rules hold it, and each fails silently if dropped:
/// - Transient failures are strikes like any other. A message that always
///   fails with a 5xx or a timeout would otherwise hold the cursor for good,
///   which is the wedge the escape hatch exists to prevent.
/// - No known last strike, or a clock that reads earlier than it, counts. A
///   clock set back by hours would otherwise keep every run "too soon" until
///   it caught up, and the hold would become that wedge.
/// - Only the incremental slice path is spaced. A held initial sync or history
///   recovery re-lists its whole window on every rerun, so spacing their
///   strikes without spacing their reruns would multiply those listings.
enum SyncFailureStrikePolicy {
    enum Spacing: Equatable, Sendable {
        /// Every failing run is a strike (history recovery).
        case everyFailingRun
        /// A failing run is a strike once this much time has passed since the
        /// last strike (the incremental slice path).
        case atLeast(TimeInterval)
    }

    /// The incremental slice path's spacing.
    static let slice = Spacing.atLeast(SyncConfig.minimumSyncFailureStrikeSpacing)

    /// Whether a failing run at `now` spends a strike.
    static func countsAsStrike(
        lastStrikeAt: Date?,
        now: Date,
        spacing: Spacing
    ) -> Bool {
        switch spacing {
        case .everyFailingRun:
            return true
        case .atLeast(let minimum):
            guard let lastStrikeAt else { return true }
            let elapsed = now.timeIntervalSince(lastStrikeAt)
            // A backward clock (elapsed < 0) or an unreadable time counts.
            guard elapsed.isFinite, elapsed >= 0 else { return true }
            return elapsed >= minimum
        }
    }

    /// The strikes a failing run proposes to `SyncFailureTracker.planHistoryAdvance`:
    /// one more, stamped `now`, when it counts, else the prior ones unchanged.
    /// A prior count already at the threshold stays there, so a hatch that was
    /// armed but refused (`deferredStagingFailed`) can still fire on a run that
    /// does not count.
    static func proposed(
        after prior: SyncFailureStrikes,
        now: Date,
        spacing: Spacing
    ) -> SyncFailureStrikes {
        guard countsAsStrike(lastStrikeAt: prior.lastStrikeAt, now: now, spacing: spacing) else {
            return prior
        }
        return SyncFailureStrikes(count: incrementedCount(after: prior.count), lastStrikeAt: now)
    }

    /// The strikes a run stages with its final save: none once its plan
    /// advanced, the proposed ones after a failing run that held, and the prior
    /// ones after a run that held with no failure (an unreadable ledger).
    static func staged(
        prior: SyncFailureStrikes,
        proposed: SyncFailureStrikes,
        hadFailures: Bool,
        advanced: Bool
    ) -> SyncFailureStrikes {
        if advanced { return .cleared }
        return hadFailures ? proposed : prior
    }

    /// Counts only as high as the escape threshold. Values above the threshold
    /// carry no additional policy meaning, and saturation avoids overflow if a
    /// future/corrupt payload somehow contains an unexpectedly large value.
    static func incrementedCount(after count: Int) -> Int {
        let threshold = Swift.max(SyncConfig.maxConsecutiveSyncFailures, 1)
        return Swift.min(Swift.max(count, 0), threshold - 1) + 1
    }
}
