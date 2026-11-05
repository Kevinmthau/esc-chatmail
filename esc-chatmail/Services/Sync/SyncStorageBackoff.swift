import Foundation

/// Whether a sync run may start given how full the disk is, and how long to wait after one
/// stopped because it was full (`sync-out-of-space-backoff` in `docs/scalability-review.md`).
///
/// Before this, a full disk failed the run's save, the run rolled back, and the 60 s foreground
/// loop started another that re-listed the frozen slice and re-fetched the uncommitted backlog in
/// full: about 2,500 quota units a minute for 500 messages, with battery and data to match, and
/// a generic "Sync failed".
///
/// Two gates, both on the same outcome (`SyncResourceAbort.insufficientStorage`):
/// - **Admission.** Below `StoreVolumeFreeSpace.lowStorageThresholdBytes` (200 MB) a run is
///   refused before it fetches anything. Reading free space costs nothing, so this gate needs
///   no backoff of its own.
/// - **Backoff.** A run that started anyway and then hit a full disk proves the reading cannot
///   be trusted, so later runs wait 1, 2, 4 … minutes, up to 30. Freeing space ends the wait
///   at once: a reading at least the threshold above the one taken at the failure admits the run.
///
/// A nil reading (the volume could not be queried) never refuses a run, as on the launch screen
/// (`AppLoadingPolicy`). Pure value type; `SyncEngine` owns the instance and the clock.
struct SyncStorageBackoff: Equatable {
    static let initialDelay: TimeInterval = 60
    static let maximumDelay: TimeInterval = 30 * 60

    private(set) var consecutiveFailures = 0
    private(set) var retryNotBefore: Date?
    /// Free space when the last run failed, so a later reading can tell that space was freed.
    private(set) var availableBytesAtFailure: Int64?

    /// The wait after this many runs in a row stopped on a full disk: 1, 2, 4 … 30 minutes.
    static func delay(afterConsecutiveFailures failures: Int) -> TimeInterval {
        guard failures > 0 else { return 0 }
        // Capped before it can overflow: 2^5 minutes already exceeds the maximum.
        let doublings = min(failures - 1, 6)
        return min(initialDelay * pow(2, Double(doublings)), maximumDelay)
    }

    /// Whether a run may start now. Refuses below the threshold, and inside a backoff window
    /// unless space has been freed since the failure that opened it.
    func admitsRun(
        now: Date,
        availableBytes: Int64?,
        threshold: Int64 = StoreVolumeFreeSpace.lowStorageThresholdBytes
    ) -> Bool {
        if let availableBytes, availableBytes < threshold {
            return false
        }
        guard let retryNotBefore, now < retryNotBefore else { return true }
        guard let availableBytes, let availableBytesAtFailure else { return false }
        return availableBytes >= availableBytesAtFailure + threshold
    }

    /// When the next run may start, for a caller scheduling its own retry. Nil when nothing waits.
    func nextAdmissionDate(now: Date) -> Date? {
        guard let retryNotBefore, now < retryNotBefore else { return nil }
        return retryNotBefore
    }

    /// A started run stopped on a full disk: open, or lengthen, the backoff window.
    mutating func recordInsufficientStorage(now: Date, availableBytes: Int64?) {
        consecutiveFailures += 1
        retryNotBefore = now.addingTimeInterval(Self.delay(afterConsecutiveFailures: consecutiveFailures))
        availableBytesAtFailure = availableBytes
    }

    /// A run finished, so its writes reached disk: the next storage failure starts the backoff
    /// over. A run that failed for any other reason changes nothing here, because a network or
    /// API failure can end a run before it writes anything.
    mutating func recordSuccessfulRun() {
        self = SyncStorageBackoff()
    }
}
