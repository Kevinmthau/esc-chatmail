import Foundation

/// Tracks sync failures and determines when to advance historyId despite failures
///
/// This prevents sync from getting permanently stuck on unfetchable messages
/// by advancing historyId after a configurable number of consecutive failures.
actor SyncFailureTracker {
    static let shared = SyncFailureTracker()

    private let defaults: UserDefaults
    private let log = LogCategory.sync.logger

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    // MARK: - Public API

    /// Records a successful sync and resets failure tracking
    func recordSuccess() {
        defaults.set(0, forKey: SyncConfig.consecutiveFailuresKey)
        defaults.removeObject(forKey: SyncConfig.persistentFailedIdsKey)
        defaults.set(Date().timeIntervalSince1970, forKey: SyncConfig.lastSuccessfulSyncTimeKey)
        log.debug("Sync success - reset failure tracking")
    }

    /// Records failed message IDs and increments failure counter
    /// - Parameter failedIds: Message IDs that failed to fetch
    func recordFailure(failedIds: [String]) {
        guard !failedIds.isEmpty else { return }

        // Increment consecutive failure count
        let consecutiveFailures = defaults.integer(forKey: SyncConfig.consecutiveFailuresKey) + 1
        defaults.set(consecutiveFailures, forKey: SyncConfig.consecutiveFailuresKey)

        // Track persistent failed IDs
        var persistentIds = defaults.stringArray(forKey: SyncConfig.persistentFailedIdsKey) ?? []
        let existingSet = Set(persistentIds)
        let newIds = failedIds.filter { !existingSet.contains($0) }
        persistentIds.append(contentsOf: newIds)

        // Limit size to prevent unbounded growth
        let maxSize = SyncConfig.maxFailedMessagesBeforeAdvance * 2
        if persistentIds.count > maxSize {
            persistentIds = Array(persistentIds.suffix(SyncConfig.maxFailedMessagesBeforeAdvance))
        }

        defaults.set(persistentIds, forKey: SyncConfig.persistentFailedIdsKey)

        log.warning("Consecutive failures: \(consecutiveFailures)/\(SyncConfig.maxConsecutiveSyncFailures), tracking \(persistentIds.count) failed IDs")
    }

    /// Determines whether historyId should be advanced despite failures
    ///
    /// Returns true if:
    /// - There were no failures (normal success case)
    /// - Maximum consecutive failures reached (to prevent deadlock)
    ///
    /// - Parameters:
    ///   - hadFailures: Whether any messages failed to fetch
    ///   - latestHistoryId: The new historyId to potentially advance to
    /// - Returns: true if historyId should be advanced
    func shouldAdvanceHistoryId(hadFailures: Bool, latestHistoryId: String) -> Bool {
        if !hadFailures {
            recordSuccess()
            return true
        }

        let consecutiveFailures = defaults.integer(forKey: SyncConfig.consecutiveFailuresKey)

        if consecutiveFailures >= SyncConfig.maxConsecutiveSyncFailures {
            log.warning("Maximum consecutive failures (\(consecutiveFailures)) reached - advancing historyId to prevent deadlock")

            // Log abandoned messages for debugging
            if let persistentFailedIds = defaults.stringArray(forKey: SyncConfig.persistentFailedIdsKey) {
                log.warning("Abandoning \(persistentFailedIds.count) unfetchable messages: \(persistentFailedIds.prefix(10))...")
            }

            // Reset tracking since we're moving forward
            recordSuccess()
            return true
        }

        log.info("Not advancing historyId - \(consecutiveFailures) consecutive failures (max: \(SyncConfig.maxConsecutiveSyncFailures))")
        return false
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

    /// Returns the IDs of persistently failed messages
    var persistentFailedIds: [String] {
        defaults.stringArray(forKey: SyncConfig.persistentFailedIdsKey) ?? []
    }

    /// Clears all failure tracking state
    func reset() {
        defaults.set(0, forKey: SyncConfig.consecutiveFailuresKey)
        defaults.removeObject(forKey: SyncConfig.persistentFailedIdsKey)
        log.debug("Failure tracking reset")
    }
}
