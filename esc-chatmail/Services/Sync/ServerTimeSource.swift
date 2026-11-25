import Foundation

/// The "now" every Gmail `after:` floor is measured against: the earlier of the device's
/// wall clock and Gmail's (`ServerClockEstimate`).
///
/// Gmail stamps mail with its own time, and the floors are compared with those stamps. A
/// device clock set ahead by hand put the stored last-sync time ahead of Gmail's, so history
/// recovery listed from a point Gmail had not reached at the last sync, and the mail
/// between was skipped for good once the recovered cursor committed
/// (architecture review, gap-wall-clock-time#1). Taking the earlier of the two can only
/// move a floor earlier than the device clock alone would, never later: a slow device
/// clock already did that, and a server estimate that is missing or wrong leaves the
/// device's time.
///
/// Not `SyncClock`: that one paces backoff and the abandoned-row drain, and a
/// `FakeSyncClock` stands in for it in tests that must not see wall-clock time at all.
protocol ServerTimeSource: Sendable {
    /// The earlier of the device's time and the estimate of Gmail's.
    func conservativeNow() -> Date
}
