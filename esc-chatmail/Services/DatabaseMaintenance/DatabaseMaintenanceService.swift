import Foundation
import CoreData

// MARK: - Database Maintenance Service

@MainActor
final class DatabaseMaintenanceService: ObservableObject {
    static let shared = DatabaseMaintenanceService()

    // Task identifiers
    static let analyzeTaskIdentifier = "com.esc.inboxchat.database.analyze"
    static let cleanupTaskIdentifier = "com.esc.inboxchat.database.cleanup"
    /// The weekly VACUUM's identifier. The task is retired: nothing schedules
    /// it and no VACUUM runs (`docs/scalability-review.md`,
    /// `weekly-full-vacuum-wal`). That review measured the weekly rewrite of
    /// the whole file through the WAL: it freed almost nothing, on a store
    /// that already vacuums incrementally, and needed about twice the
    /// store's size in free disk to do it.
    ///
    /// The identifier is still registered, and still listed in `Info.plist`
    /// (`BGTaskSchedulerPermittedIdentifiers`): a device that ran an earlier
    /// build can have a request for it waiting with the system, and
    /// `BGTaskScheduler` raises when it launches the app for an identifier
    /// with no handler. Keep `retire` and the `Info.plist` entry for at least
    /// one release after the build that stopped scheduling it.
    static let retiredVacuumTaskIdentifier = "com.esc.inboxchat.database.vacuum"

    // Internal for extension access
    let coreDataStack: CoreDataStack
    let taskRegistry: any BackgroundTaskRegistering
    /// Awaited first by both maintenance handlers, before the maintenance run
    /// is asked for and before anything touches the store. A cold background
    /// launch reaches these handlers without `initializeApp`, so without it
    /// the handler made the store's first load itself (migration and recovery
    /// ladder included) ahead of the fresh-install cleanup, and went on
    /// against a coordinator with no store when that load was kept as failed.
    /// The default is the single-attempt `preparePersistenceIfNeeded()`, as
    /// background sync's: never the foreground's retry loop, which does not
    /// end in a background task, and never the auth restore, which takes the
    /// account boundary that the maintenance run waits on.
    let persistenceReadiness: @Sendable () async -> Bool
    /// The exclusive maintenance run both tasks take. `.shared` in the app.
    let storeMaintenanceCoordinator: StoreMaintenanceCoordinator
    /// The boundary the cleanup's body sweep removes files through. Asked
    /// for when a cleanup runs, not here: `.shared` makes and marks the
    /// `Messages` directory, and this service is built in `App.init`, a Mac
    /// unit-test host's included, whose container is the real one.
    let htmlContentHandler: @Sendable () -> HTMLContentHandler
    /// The cleanup's last step, the sweep of `Attachments` and `Previews`.
    let sweepOrphanedAttachmentFiles: @Sendable () async -> Void
    /// Builds the cleanup's store-wide passes over this service's stack.
    let makeDataCleanupService: @Sendable (CoreDataStack) -> DataCleanupService

    /// Internal (not private) only so tests can inject a seamed registry.
    /// Never construct a second instance against the default `.shared`
    /// registry: `registerBackgroundTasks()` runs in here, and a repeat
    /// registration of the same identifier with the real `BGTaskScheduler`
    /// is an Apple assertion failure that aborts the process, not a
    /// recoverable error. The default is `BackgroundTaskRegistry` on iOS and
    /// `BackgroundActivityTaskRegistry` (`NSBackgroundActivityScheduler`) on
    /// the Mac. It is resolved here rather than in the parameter list because
    /// the Mac registry's `shared` is main-actor isolated, and a default
    /// argument is evaluated outside this initializer's isolation.
    ///
    /// The other parameters are for tests too. A test that runs a handler or
    /// `performCleanup()` injects all of them: the defaults are the app's
    /// shared run boundary and its real `Messages`, `Attachments` and
    /// `Previews` directories, and the default readiness, which refuses in a
    /// unit-test host, would otherwise run the real `FreshInstallHandler` on
    /// the host's defaults.
    init(
        taskRegistry: (any BackgroundTaskRegistering)? = nil,
        coreDataStack: CoreDataStack = .shared,
        persistenceReadiness: @escaping @Sendable () async -> Bool = {
            // A task the system delivers to a unit-test host must not run
            // the launch bootstrap there.
            guard !RuntimeEnvironment.isRunningUnitTests else { return false }
            return await AppStartupBootstrap.shared.preparePersistenceIfNeeded()
        },
        storeMaintenanceCoordinator: StoreMaintenanceCoordinator = .shared,
        htmlContentHandler: @escaping @Sendable () -> HTMLContentHandler = { .shared },
        sweepOrphanedAttachmentFiles: @escaping @Sendable () async -> Void = {
            await AttachmentDownloader.shared.cleanupOrphanedFiles()
        },
        makeDataCleanupService: @escaping @Sendable (CoreDataStack) -> DataCleanupService = { coreDataStack in
            DataCleanupService(coreDataStack: coreDataStack)
        }
    ) {
        self.taskRegistry = taskRegistry ?? PlatformBackgroundTaskRegistry.shared
        self.coreDataStack = coreDataStack
        self.persistenceReadiness = persistenceReadiness
        self.storeMaintenanceCoordinator = storeMaintenanceCoordinator
        self.htmlContentHandler = htmlContentHandler
        self.sweepOrphanedAttachmentFiles = sweepOrphanedAttachmentFiles
        self.makeDataCleanupService = makeDataCleanupService
        registerBackgroundTasks()
    }

    // MARK: - Background Task Registration

    func registerBackgroundTasks() {
        // A handler that does nothing, and the pending request cancelled.
        taskRegistry.retire(Self.retiredVacuumTaskIdentifier)

        // Register analyze task (runs daily)
        taskRegistry.register(
            config: .dailyProcessing(
                identifier: Self.analyzeTaskIdentifier,
                requiresNetwork: false,
                requiresPower: false
            ),
            handler: { [weak self] in
                guard let self, await self.persistenceReadiness() else { return false }
                return await self.performAnalyze()
            }
        )

        // Register cleanup task (runs daily)
        taskRegistry.register(
            config: .dailyProcessing(
                identifier: Self.cleanupTaskIdentifier,
                requiresNetwork: false,
                requiresPower: false
            ),
            handler: { [weak self] in
                guard let self, await self.persistenceReadiness() else { return false }
                return await self.performCleanup()
            }
        )
    }

    /// Submits the two maintenance requests, skipping any still pending with
    /// the system. This runs on every cold launch, and a `BGTaskScheduler`
    /// submit with a pending identifier REPLACES that request — unconditional
    /// re-submits pushed cleanup/analyze eligibility past every overnight
    /// window for a user who launches daily, so the cleanup task never ran at
    /// all.
    /// On the Mac a pending activity lives only in this process, so the
    /// registry instead resumes each job's persisted due date
    /// (`BackgroundActivitySchedulePolicy`).
    func scheduleMaintenanceTasks() async {
        await taskRegistry.scheduleIfNotPending([
            Self.analyzeTaskIdentifier,
            Self.cleanupTaskIdentifier
        ])
    }
}
