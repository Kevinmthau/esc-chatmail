#if os(macOS)
import Foundation
import IOKit.ps

/// The Mac maintenance scheduler. `BackgroundTaskRegistry`, the iOS one, is
/// built on `BGTaskScheduler`, which macOS does not have.
typealias PlatformBackgroundTaskRegistry = BackgroundActivityTaskRegistry

/// Runs the registered maintenance jobs (vacuum, analyze, cleanup) as
/// `NSBackgroundActivityScheduler` activities, which the system starts when
/// energy, thermal state and CPU load suit it.
///
/// Each job is a one-shot activity aimed at a persisted due date, re-armed a
/// full interval out after every run. A repeating activity would restart its
/// clock at every launch, because nothing about it survives a quit;
/// `BackgroundActivitySchedulePolicy` explains why that would keep the weekly
/// vacuum from ever running and owns the timing rules.
///
/// MainActor-isolated: registration and scheduling run on the main thread,
/// and the activity block, which the system calls on a background queue, hops
/// here before it touches any state.
@MainActor
final class BackgroundActivityTaskRegistry: BackgroundTaskRegistering {
    static let shared = BackgroundActivityTaskRegistry()

    private struct Registration {
        let config: BackgroundTaskConfiguration
        let handler: () async -> Bool
    }

    /// `token` tells the activity's own block which schedule it belongs to,
    /// since the block cannot capture the (non-`Sendable`) scheduler itself.
    private struct ScheduledActivity {
        let token: UUID
        let scheduler: NSBackgroundActivityScheduler
    }

    private static let dueDateKeyPrefix = "backgroundActivity.dueDate."

    private let defaults: UserDefaults
    private let now: @Sendable () -> Date
    private var registrations: [String: Registration] = [:]
    /// The activity waiting for each identifier. Activities exist only in this
    /// process, so this map is what "pending" means here; the persisted due
    /// date is what carries a schedule across launches.
    private var scheduledActivities: [String: ScheduledActivity] = [:]
    private var runningIdentifiers: Set<String> = []

    init(
        defaults: UserDefaults = .standard,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.defaults = defaults
        self.now = now
    }

    func register(
        config: BackgroundTaskConfiguration,
        handler: @escaping () async -> Bool
    ) {
        registrations[config.identifier] = Registration(config: config, handler: handler)
        Log.debug("Registered background activity: \(config.identifier)", category: .background)
    }

    func scheduleIfNotPending(_ identifiers: [String]) async {
        for identifier in identifiers {
            if scheduledActivities[identifier] != nil || runningIdentifiers.contains(identifier) {
                Log.debug("Skipping still-pending background activity: \(identifier)", category: .background)
            } else {
                schedule(identifier)
            }
        }
    }

    private func schedule(_ identifier: String) {
        guard let registration = registrations[identifier] else {
            Log.warning("Cannot schedule unknown background activity: \(identifier)", category: .background)
            return
        }

        let jobInterval = registration.config.interval
        let scheduledAt = now()
        let dueDate = BackgroundActivitySchedulePolicy.dueDate(
            stored: storedDueDate(for: identifier),
            jobInterval: jobInterval,
            now: scheduledAt
        )
        storeDueDate(dueDate, for: identifier)
        let timing = BackgroundActivitySchedulePolicy.activityTiming(
            dueDate: dueDate,
            jobInterval: jobInterval,
            now: scheduledAt
        )

        let scheduler = NSBackgroundActivityScheduler(identifier: identifier)
        scheduler.repeats = false
        scheduler.interval = timing.interval
        scheduler.tolerance = timing.tolerance
        scheduler.qualityOfService = .background
        let token = UUID()
        scheduledActivities[identifier] = ScheduledActivity(token: token, scheduler: scheduler)

        scheduler.schedule { [weak self] completion in
            Task { @MainActor in
                guard let self else {
                    completion(.finished)
                    return
                }
                await self.runActivity(identifier, token: token, completion: completion)
            }
        }
        Log.debug("Scheduled background activity: \(identifier)", category: .background)
    }

    private func runActivity(
        _ identifier: String,
        token: UUID,
        completion: @escaping NSBackgroundActivityScheduler.CompletionHandler
    ) async {
        guard let activity = scheduledActivities[identifier],
              activity.token == token,
              let registration = registrations[identifier] else {
            completion(.finished)
            return
        }

        if BackgroundActivitySchedulePolicy.shouldDefer(
            systemRequestsDeferral: activity.scheduler.shouldDefer,
            requiresExternalPower: registration.config.requiresExternalPower,
            isOnExternalPower: Self.isOnExternalPower()
        ) {
            // The system calls the block again later; the activity stays
            // pending, so a launch-time schedule still skips it.
            completion(.deferred)
            return
        }

        scheduledActivities[identifier] = nil
        runningIdentifiers.insert(identifier)
        let success = await registration.handler()
        runningIdentifiers.remove(identifier)
        storeDueDate(
            BackgroundActivitySchedulePolicy.dueDate(
                afterRunFinishedAt: now(),
                jobInterval: registration.config.interval
            ),
            for: identifier
        )
        completion(.finished)
        Log.debug("Background activity \(identifier) finished (success: \(success))", category: .background)

        schedule(identifier)
    }

    private func storedDueDate(for identifier: String) -> Date? {
        defaults.object(forKey: Self.dueDateKeyPrefix + identifier) as? Date
    }

    private func storeDueDate(_ dueDate: Date, for identifier: String) {
        defaults.set(dueDate, forKey: Self.dueDateKeyPrefix + identifier)
    }

    /// True on AC power or a UPS, and on a Mac with no battery.
    private static func isOnExternalPower() -> Bool {
        IOPSGetTimeRemainingEstimate() == kIOPSTimeRemainingUnlimited
    }
}
#endif
