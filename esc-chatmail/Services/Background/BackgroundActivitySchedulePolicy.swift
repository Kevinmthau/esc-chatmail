import Foundation

/// When the Mac's `BackgroundActivityTaskRegistry` lets a maintenance job run.
///
/// Pure and compiled on both platforms so the timing rules are tested under
/// the iOS test plan; only the Mac schedules through it.
///
/// An `NSBackgroundActivityScheduler` activity lives only as long as the
/// process, so a repeating activity's clock would restart at every launch: a
/// user who quits and relaunches more often than once a week would never see
/// the weekly vacuum run. That is the Mac form of the iOS bug where
/// re-submitting a pending `BGTaskScheduler` request pushed its
/// `earliestBeginDate` out again (`BackgroundTaskRegistry.scheduleIfNotPending`).
/// So each job keeps a persisted due date, and each launch schedules a one-shot
/// activity for whatever is left of it.
enum BackgroundActivitySchedulePolicy {
    /// No job runs sooner than this after it is scheduled, so a launch or a
    /// re-arm never starts a vacuum or analyze while the first sync is busy
    /// with the same store.
    static let minimumDelay: TimeInterval = 15 * 60

    /// The most the system may move a run away from its nominal time.
    static let maximumTolerance: TimeInterval = 60 * 60

    /// An `NSBackgroundActivityScheduler`'s `interval` and `tolerance`. For a
    /// one-shot activity the system runs it between `interval - tolerance` and
    /// `interval + tolerance` after it is scheduled.
    struct ActivityTiming: Equatable, Sendable {
        let interval: TimeInterval
        let tolerance: TimeInterval
    }

    /// The date a job becomes due. With no stored date it is one full interval
    /// from now, as the first iOS submit sets `earliestBeginDate`. A stored
    /// date more than one interval away (the clock was set back) is pulled in
    /// to one interval from now, so the job cannot be postponed indefinitely.
    static func dueDate(stored: Date?, jobInterval: TimeInterval, now: Date) -> Date {
        let latestDueDate = now.addingTimeInterval(jobInterval)
        guard let stored else { return latestDueDate }
        return min(stored, latestDueDate)
    }

    /// Timing that never runs the job before `dueDate`, nor sooner than
    /// `minimumDelay` from now, and lets the system pick a moment within
    /// twice the tolerance after that.
    static func activityTiming(dueDate: Date, jobInterval: TimeInterval, now: Date) -> ActivityTiming {
        let delay = max(dueDate.timeIntervalSince(now), minimumDelay)
        let tolerance = min(jobInterval / 4, maximumTolerance)
        return ActivityTiming(interval: delay + tolerance, tolerance: tolerance)
    }

    /// The due date after a run, successful or not: one full interval after
    /// it finished. iOS re-submits after every fired task the same way
    /// (`BackgroundTaskRegistry.handleTask`).
    static func dueDate(afterRunFinishedAt finishedAt: Date, jobInterval: TimeInterval) -> Date {
        finishedAt.addingTimeInterval(jobInterval)
    }

    /// Whether a due activity should hand its turn back to the system instead
    /// of running. `requiresExternalPower` is the Mac reading of the iOS
    /// `BGProcessingTaskRequest` flag the weekly vacuum sets: wait for AC power.
    static func shouldDefer(
        systemRequestsDeferral: Bool,
        requiresExternalPower: Bool,
        isOnExternalPower: Bool
    ) -> Bool {
        systemRequestsDeferral || (requiresExternalPower && !isOnExternalPower)
    }
}
