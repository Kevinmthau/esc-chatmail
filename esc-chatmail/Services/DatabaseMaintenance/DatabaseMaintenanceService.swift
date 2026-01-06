import Foundation
import CoreData
import BackgroundTasks

// MARK: - Database Maintenance Service

@MainActor
final class DatabaseMaintenanceService: ObservableObject {
    static let shared = DatabaseMaintenanceService()

    // Task identifiers
    static let vacuumTaskIdentifier = "com.esc.inboxchat.database.vacuum"
    static let analyzeTaskIdentifier = "com.esc.inboxchat.database.analyze"
    static let cleanupTaskIdentifier = "com.esc.inboxchat.database.cleanup"

    @Published var isPerformingMaintenance = false
    @Published var lastMaintenanceDate: Date?
    @Published var maintenanceProgress: Double = 0.0

    // Internal for extension access
    let coreDataStack = CoreDataStack.shared
    let taskRegistry = BackgroundTaskRegistry.shared

    private init() {
        registerBackgroundTasks()
        loadLastMaintenanceDate()
    }

    // MARK: - Background Task Registration

    func registerBackgroundTasks() {
        // Register vacuum task (runs weekly, requires power)
        taskRegistry.register(
            config: .weeklyProcessing(
                identifier: Self.vacuumTaskIdentifier,
                requiresNetwork: false,
                requiresPower: true
            ),
            handler: { [weak self] in
                await self?.performVacuum() ?? false
            }
        )

        // Register analyze task (runs daily)
        taskRegistry.register(
            config: .dailyProcessing(
                identifier: Self.analyzeTaskIdentifier,
                requiresNetwork: false,
                requiresPower: false
            ),
            handler: { [weak self] in
                await self?.performAnalyze() ?? false
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
                await self?.performCleanup() ?? false
            }
        )
    }

    func scheduleMaintenanceTasks() {
        taskRegistry.schedule(Self.vacuumTaskIdentifier)
        taskRegistry.schedule(Self.analyzeTaskIdentifier)
        taskRegistry.schedule(Self.cleanupTaskIdentifier)
    }

    // MARK: - Full Maintenance Orchestration

    func performFullMaintenance() async -> Bool {
        await MainActor.run {
            isPerformingMaintenance = true
            maintenanceProgress = 0.0
        }

        defer {
            Task { @MainActor in
                isPerformingMaintenance = false
                maintenanceProgress = 1.0
                lastMaintenanceDate = Date()
                saveLastMaintenanceDate()
            }
        }

        // Step 1: Cleanup old data
        await MainActor.run { maintenanceProgress = 0.1 }
        let cleanupSuccess = await performCleanup()

        // Step 2: Analyze database
        await MainActor.run { maintenanceProgress = 0.4 }
        let analyzeSuccess = await performAnalyze()

        // Step 3: Vacuum database
        await MainActor.run { maintenanceProgress = 0.7 }
        let vacuumSuccess = await performVacuum()

        // Step 4: Rebuild indexes
        await MainActor.run { maintenanceProgress = 0.9 }
        let indexSuccess = await rebuildIndexes()

        return cleanupSuccess && analyzeSuccess && vacuumSuccess && indexSuccess
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
