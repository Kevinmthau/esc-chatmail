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

    @Published var lastMaintenanceDate: Date?

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
    /// `coreDataStack` and `persistenceReadiness` are for tests too. A test
    /// injects both, because the default readiness runs the real
    /// `FreshInstallHandler` on the host's defaults.
    init(
        taskRegistry: (any BackgroundTaskRegistering)? = nil,
        coreDataStack: CoreDataStack = .shared,
        persistenceReadiness: @escaping @Sendable () async -> Bool = {
            await AppStartupBootstrap.shared.preparePersistenceIfNeeded()
        }
    ) {
        self.taskRegistry = taskRegistry ?? PlatformBackgroundTaskRegistry.shared
        self.coreDataStack = coreDataStack
        self.persistenceReadiness = persistenceReadiness
        registerBackgroundTasks()
        loadLastMaintenanceDate()
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

    // MARK: - Persistence

    func loadLastMaintenanceDate() {
        lastMaintenanceDate = UserDefaults.standard.object(forKey: "LastDatabaseMaintenance") as? Date
    }

    func saveLastMaintenanceDate() {
        UserDefaults.standard.set(lastMaintenanceDate, forKey: "LastDatabaseMaintenance")
    }
}

// MARK: - Database Statistics

struct DatabaseStatistics: Sendable {
    let messageCount: Int
    let conversationCount: Int
    let attachmentCount: Int
    let personCount: Int
    let databaseSize: Int64
    let lastMaintenanceDate: Date?

    var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: databaseSize, countStyle: .file)
    }

    var needsMaintenance: Bool {
        guard let lastDate = lastMaintenanceDate else { return true }
        return Date().timeIntervalSince(lastDate) > 7 * 24 * 60 * 60 // 7 days
    }
}
