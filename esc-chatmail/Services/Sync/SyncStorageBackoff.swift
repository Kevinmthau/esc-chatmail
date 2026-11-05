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
/// A nil reading (the volume could not be queried) never trips the admission threshold, as on
/// the launch screen (`AppLoadingPolicy`). Inside a backoff window it does refuse: a run just hit a
/// full disk, and a reading that cannot be taken cannot show that space was freed, so the window
/// runs its course. Pure value type; `SyncEngine` owns the instance and the clock.
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

    /// A started run stopped on a full disk: open, or lengthen, the backoff window.
    mutating func recordInsufficientStorage(now: Date, availableBytes: Int64?) {
        consecutiveFailures += 1
        retryNotBefore = now.addingTimeInterval(Self.delay(afterConsecutiveFailures: consecutiveFailures))
        availableBytesAtFailure = availableBytes
    }

    /// A run finished. Only one that stored mail proves the disk takes message writes, so only
    /// that one starts the backoff over. A run that stored nothing (no new mail, a label-only
    /// slice, a deferred history recovery) can succeed on a disk still too full for message
    /// bodies, and resetting on it would hold the backoff at its first minute while the disk
    /// stays full. A run that failed for any other reason does not reach here, because a network
    /// or API failure can end a run before it writes anything.
    ///
    /// History recovery reports no new messages even when it stored some, so it leaves the
    /// backoff as it was. That only makes the next window longer than it needed to be.
    mutating func recordSuccessfulRun(storedMessageCount: Int) {
        guard storedMessageCount > 0 else { return }
        self = SyncStorageBackoff()
    }

    /// Whether a run that just finished lifts the "storage is full" banner
    /// (`SyncEngine.isBlockedByInsufficientStorage`). Call it after the run has reported what it
    /// stored (`recordSuccessfulRun(storedMessageCount:)`).
    ///
    /// The banner follows the same evidence as the backoff. While a full-disk stop is outstanding
    /// (`consecutiveFailures > 0`) it lifts only on what would also end the backoff: the run
    /// stored mail (which has already reset the backoff, so this sees no failure), or a reading
    /// shows space freed since the stop, the test `admitsRun` uses to end a window early. A run
    /// that merely succeeded proves nothing on a disk still too full for message bodies: it used
    /// to lift the banner after every run with no new mail, and the next real message raised it
    /// again. A reading at or above the admission threshold is not enough on its own either,
    /// because the stop being answered happened on a disk that read above it.
    ///
    /// With no stop outstanding, the banner came from an admission refusal alone, and this run
    /// passed that same admission gate on its way in, so it lifts.
    func liftsInsufficientStorageBanner(
        availableBytes: Int64?,
        threshold: Int64 = StoreVolumeFreeSpace.lowStorageThresholdBytes
    ) -> Bool {
        guard consecutiveFailures > 0 else { return true }
        guard let availableBytes, let availableBytesAtFailure else { return false }
        return availableBytes >= availableBytesAtFailure + threshold
    }
}
