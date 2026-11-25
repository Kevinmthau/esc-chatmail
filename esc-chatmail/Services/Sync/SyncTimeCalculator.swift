import Foundation

/// Centralized time calculations for sync operations
///
/// Eliminates duplicate timestamp buffer logic across:
/// - InitialSyncOrchestrator
/// - IncrementalSyncOrchestrator (history recovery)
/// - SyncReconciliation
struct SyncTimeCalculator {

    // MARK: - Configuration

    /// Configuration for different sync operation types
    struct Config {
        /// Buffer to subtract from primary timestamp (e.g., last sync time)
        let primaryBuffer: TimeInterval

        /// Buffer to subtract from install timestamp
        let installBuffer: TimeInterval

        /// Fallback window when no timestamps are available
        let fallbackWindow: TimeInterval

        /// Maximum window to cap results (nil = no cap)
        let maxWindow: TimeInterval?

        /// Whether to try last sync time before install timestamp
        let useLastSyncAsPrimary: Bool

        /// Configuration for initial sync
        /// Uses install timestamp only, with 30-day fallback, capped at 30 days.
        ///
        /// `installTimestamp` is the mailbox's start
        /// (`SyncConfig.mailboxStartTimestampKey`): the first launch, then
        /// every wipe of the local mailbox and every interactive sign-in onto
        /// an empty store, so a sign-in after a sign-out lists only mail from
        /// the sign-in on. A store reset or a missing cursor moves nothing,
        /// and uncapped, the install branch made such a re-initial sync
        /// re-list and full-fetch everything since the mailbox began in one
        /// run. The cap bounds that run. Callers freeze
        /// the result at a run's first attempt (`SyncWindowCheckpointStore`),
        /// so a retry never slides the lower bound past mail it still owes.
        static let initialSync = Config(
            primaryBuffer: SyncConfig.timestampBufferSeconds,
            installBuffer: SyncConfig.timestampBufferSeconds,
            fallbackWindow: SyncConfig.initialSyncFallbackWindow,
            maxWindow: SyncConfig.initialSyncMaxWindow,
            useLastSyncAsPrimary: false
        )

        /// Configuration for history recovery sync
        /// Tries last sync first (10-min buffer), then install (5-min buffer), with 7-day fallback.
        ///
        /// Deliberately uncapped: `maxWindow` also caps the last-sync branch,
        /// so an ordinary absence longer than the cap would skip mail and
        /// advance the cursor past the gap. Only the install branch is bounded,
        /// by `historyRecoveryInstallBranchStartTime`.
        static let historyRecovery = Config(
            primaryBuffer: SyncConfig.recoveryBufferSeconds,
            installBuffer: SyncConfig.timestampBufferSeconds,
            fallbackWindow: SyncConfig.recoveryFallbackWindow,
            maxWindow: nil,
            useLastSyncAsPrimary: true
        )

        /// Configuration for reconciliation
        /// Tries last sync first (5-min buffer), with 1-hour fallback, capped at 24 hours
        static let reconciliation = Config(
            primaryBuffer: SyncConfig.timestampBufferSeconds,
            installBuffer: SyncConfig.timestampBufferSeconds,
            fallbackWindow: SyncConfig.reconciliationInterval,
            maxWindow: SyncConfig.maxReconciliationWindow,
            useLastSyncAsPrimary: true
        )
    }

    // MARK: - Public API

    /// Calculates the start timestamp for sync operations
    ///
    /// Priority order depends on config:
    /// 1. Last successful sync (if useLastSyncAsPrimary = true) minus primaryBuffer
    /// 2. Install timestamp minus installBuffer
    /// 3. Fallback window from now
    ///
    /// Results are capped by maxWindow if specified and never go before install cutoff.
    ///
    /// The stored last-sync time and mailbox start are read as no later than `now`
    /// (`clampedToNow`): a device clock that was set ahead when they were written left
    /// them past Gmail's time, and a floor drawn from them skipped the mail between. The
    /// clamp can only move a floor earlier. Callers pass `now` from their
    /// `ServerTimeSource`, the earlier of the device's time and Gmail's; a clamp to the
    /// device's own time alone helps nothing while the device is still ahead.
    ///
    /// - Parameters:
    ///   - config: Configuration determining which timestamps to check and buffers to apply
    ///   - installTimestamp: Optional explicit install timestamp (defaults to UserDefaults value)
    ///   - now: Optional explicit current time (defaults to the system clock)
    ///   - defaults: Where `lastSuccessfulSyncTime` and `installTimestamp` are read from
    /// - Returns: The calculated start timestamp as TimeInterval since 1970
    static func calculateStartTime(
        config: Config,
        installTimestamp: TimeInterval? = nil,
        now: TimeInterval? = nil,
        defaults: UserDefaults = .standard
    ) -> TimeInterval {
        let now = now ?? Date().timeIntervalSince1970
        let install = clampedToNow(
            installTimestamp ?? defaults.double(forKey: SyncConfig.mailboxStartTimestampKey),
            now: now
        )

        // Try last successful sync first (if configured)
        if config.useLastSyncAsPrimary {
            let lastSuccessfulSync = clampedToNow(
                defaults.double(forKey: SyncConfig.lastSuccessfulSyncTimeKey),
                now: now
            )
            if lastSuccessfulSync > 0 {
                var startTime = lastSuccessfulSync - config.primaryBuffer

                // Apply max window cap if specified
                if let maxWindow = config.maxWindow {
                    let minAllowedTime = now - maxWindow
                    startTime = max(startTime, minAllowedTime)
                }

                // Never go before install cutoff
                if install > 0 {
                    let installCutoff = install - config.installBuffer
                    startTime = max(startTime, installCutoff)
                }

                return startTime
            }
        }

        // Try install timestamp
        if install > 0 {
            var startTime = install - config.installBuffer
            if let maxWindow = config.maxWindow {
                let minAllowedTime = now - maxWindow
                startTime = max(startTime, minAllowedTime)
            }
            return startTime
        }

        // Fallback
        var startTime = now - config.fallbackWindow
        if let maxWindow = config.maxWindow {
            let minAllowedTime = now - maxWindow
            startTime = max(startTime, minAllowedTime)
        }
        return startTime
    }

    /// Calculates the start time as a Date
    static func calculateStartDate(
        config: Config,
        installTimestamp: TimeInterval? = nil,
        now: TimeInterval? = nil,
        defaults: UserDefaults = .standard
    ) -> Date {
        let timestamp = calculateStartTime(
            config: config,
            installTimestamp: installTimestamp,
            now: now,
            defaults: defaults
        )
        return Date(timeIntervalSince1970: timestamp)
    }

    /// A stored time read as no later than `now`; zero (unset) stays zero.
    static func clampedToNow(_ stored: TimeInterval, now: TimeInterval) -> TimeInterval {
        stored > 0 ? min(stored, now) : stored
    }

    /// Lower bound for a history recovery that has no `lastSuccessfulSyncTime`
    /// (teardown clears it, including the store-preserving paths that keep the
    /// expired cursor). The install branch would re-list every message since
    /// install; the newest received row already in the store marks how far
    /// earlier syncs got, so recovery starts there, less the recovery buffer.
    ///
    /// Received rows only: an optimistic send stamps a local `now` and would
    /// skip mail that arrived before it. The caller must derive this once, on
    /// a recovery's first attempt, and freeze it: recovery saves pages
    /// newest-first, so re-deriving on a retry would start after the gap the
    /// interrupted attempt never finished. With no received row there is
    /// nothing to anchor on and the unbounded install branch stands.
    static func historyRecoveryInstallBranchStartTime(
        newestReceivedInternalDate: TimeInterval?,
        installTimestamp: TimeInterval? = nil,
        now: TimeInterval? = nil,
        defaults: UserDefaults = .standard
    ) -> TimeInterval {
        let config = Config.historyRecovery
        let now = now ?? Date().timeIntervalSince1970
        let install = clampedToNow(
            installTimestamp ?? defaults.double(forKey: SyncConfig.mailboxStartTimestampKey),
            now: now
        )
        guard let newestReceivedInternalDate else {
            if install > 0 {
                return install - config.installBuffer
            }
            return now - config.fallbackWindow
        }

        var startTime = min(newestReceivedInternalDate, now) - config.primaryBuffer
        if install > 0 {
            startTime = max(startTime, install - config.installBuffer)
        }
        return startTime
    }

    /// Builds a Gmail API query string with the calculated start time
    ///
    /// Query format: `after:{timestamp} -label:spam -label:drafts -label:trash`
    ///
    /// - Parameters:
    ///   - config: Configuration for time calculation
    ///   - installTimestamp: Optional explicit install timestamp
    /// - Returns: Gmail search query string
    static func buildSyncQuery(
        config: Config,
        installTimestamp: TimeInterval? = nil
    ) -> String {
        buildSyncQuery(startTime: calculateStartTime(config: config, installTimestamp: installTimestamp))
    }

    /// Builds the Gmail API query string for an already-resolved start time.
    static func buildSyncQuery(startTime: TimeInterval) -> String {
        "after:\(Int(startTime)) -label:spam -label:drafts -label:trash"
    }
}
