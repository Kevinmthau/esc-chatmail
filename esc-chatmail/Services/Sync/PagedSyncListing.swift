import Foundation

/// The listing an initial sync or a history recovery runs: its frozen window
/// and, where an earlier attempt stopped part-way and may still be resumed,
/// that attempt's page progress.
struct PagedSyncListing: Equatable, Sendable {
    let windowStart: TimeInterval
    let progress: PagedSyncProgress?

    var query: String {
        SyncTimeCalculator.buildSyncQuery(startTime: windowStart)
    }

    init(windowStart: TimeInterval, progress: PagedSyncProgress?) {
        self.windowStart = windowStart
        self.progress = progress
    }

    /// The frozen window, with its progress only while it may be resumed
    /// (`PagedSyncProgress.isResumable(at:)`). A listing too old to resume
    /// lists the same window again from its first page: the IDs its pages
    /// failed are in that window and are listed again.
    init(resuming frozen: SyncWindowCheckpoint, now: TimeInterval) {
        windowStart = frozen.windowStart
        if let progress = frozen.progress, progress.isResumable(at: now) {
            self.progress = progress
        } else {
            if frozen.progress != nil {
                Log.info(
                    "Interrupted sync listing is too old to resume; listing its window again",
                    category: .sync
                )
            }
            progress = nil
        }
    }
}
