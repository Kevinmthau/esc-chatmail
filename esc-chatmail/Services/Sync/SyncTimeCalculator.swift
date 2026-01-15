import Foundation

/// Centralized time calculations for sync operations
///
/// Eliminates duplicate timestamp buffer logic across:
/// - InitialSyncOrchestrator.buildInitialSyncQuery()
/// - IncrementalSyncOrchestrator.calculateRecoveryStartTime()
/// - SyncReconciliation.calculateReconciliationStartTime()
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
        /// Uses install timestamp only, with 30-day fallback
        static let initialSync = Config(
            primaryBuffer: SyncConfig.timestampBufferSeconds,
            installBuffer: SyncConfig.timestampBufferSeconds,
            fallbackWindow: SyncConfig.initialSyncFallbackWindow,
            maxWindow: nil,
            useLastSyncAsPrimary: false
        )

        /// Configuration for history recovery sync
        /// Tries last sync first (10-min buffer), then install (5-min buffer), with 7-day fallback
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
    /// - Parameters:
    ///   - config: Configuration determining which timestamps to check and buffers to apply
    ///   - installTimestamp: Optional explicit install timestamp (defaults to UserDefaults value)
    /// - Returns: The calculated start timestamp as TimeInterval since 1970
    static func calculateStartTime(
        config: Config,
        installTimestamp: TimeInterval? = nil
    ) -> TimeInterval {
        let defaults = UserDefaults.standard
        let now = Date().timeIntervalSince1970
        let install = installTimestamp ?? defaults.double(forKey: "installTimestamp")

        // Try last successful sync first (if configured)
        if config.useLastSyncAsPrimary {
            let lastSuccessfulSync = defaults.double(forKey: SyncConfig.lastSuccessfulSyncTimeKey)
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
            return install - config.installBuffer
        }

        // Fallback
        return now - config.fallbackWindow
    }

    /// Calculates the start time as a Date
    static func calculateStartDate(
        config: Config,
        installTimestamp: TimeInterval? = nil
    ) -> Date {
        let timestamp = calculateStartTime(config: config, installTimestamp: installTimestamp)
        return Date(timeIntervalSince1970: timestamp)
    }

    /// Builds a Gmail API query string with the calculated start time
    ///
    /// Query format: `after:{timestamp} -label:spam -label:drafts`
    ///
    /// - Parameters:
    ///   - config: Configuration for time calculation
    ///   - installTimestamp: Optional explicit install timestamp
    /// - Returns: Gmail search query string
    static func buildSyncQuery(
        config: Config,
        installTimestamp: TimeInterval? = nil
    ) -> String {
        let startTime = Int(calculateStartTime(config: config, installTimestamp: installTimestamp))
        return "after:\(startTime) -label:spam -label:drafts"
    }
}
