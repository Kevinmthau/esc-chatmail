import Foundation

/// The surface `DatabaseMaintenanceService` schedules its analyze and
/// cleanup jobs through, so the jobs stay platform-neutral while the scheduler
/// underneath is not: `BackgroundTaskRegistry` submits `BGTaskScheduler`
/// requests on iOS, and `BackgroundActivityTaskRegistry` runs
/// `NSBackgroundActivityScheduler` activities on the Mac, where every `BG*`
/// type is unavailable. `PlatformBackgroundTaskRegistry` names the one each
/// platform uses.
///
/// MainActor-isolated because registration happens on the main thread during
/// launch (see `BackgroundTaskRegistry.init`) and the service calling it is a
/// main-actor type.
@MainActor
protocol BackgroundTaskRegistering: AnyObject {
    /// Records the job's configuration and handler. Schedules nothing: the
    /// first submit is `scheduleIfNotPending(_:)`'s.
    func register(
        config: BackgroundTaskConfiguration,
        handler: @escaping () async -> Bool
    )

    /// Schedules each registered identifier that is not already waiting to
    /// run. An identifier that is still pending keeps its existing due date:
    /// re-submitting it would push that date a full interval out again, so a
    /// user who launches more often than the interval would never see the
    /// job run.
    func scheduleIfNotPending(_ identifiers: [String]) async

    /// Takes a job the app no longer runs out of the schedule: whatever is
    /// waiting for `identifier` is cancelled, and a run of it that the system
    /// starts anyway does nothing and finishes at once. Call it in place of
    /// `register` for that identifier, at the point `register` was called.
    func retire(_ identifier: String)
}
