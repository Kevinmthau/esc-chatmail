import Foundation
import CoreData
import BackgroundTasks
import SQLite3

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

    private let coreDataStack = CoreDataStack.shared
    private var maintenanceTimer: Timer?

    private init() {
        registerBackgroundTasks()
        loadLastMaintenanceDate()
    }

    // MARK: - Background Task Registration

    func registerBackgroundTasks() {
        // Register vacuum task (runs weekly)
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: Self.vacuumTaskIdentifier,
            using: nil
        ) { task in
            self.handleVacuumTask(task: task as! BGProcessingTask)
        }

        // Register analyze task (runs daily)
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: Self.analyzeTaskIdentifier,
            using: nil
        ) { task in
            self.handleAnalyzeTask(task: task as! BGProcessingTask)
        }

        // Register cleanup task (runs daily)
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: Self.cleanupTaskIdentifier,
            using: nil
        ) { task in
            self.handleCleanupTask(task: task as! BGProcessingTask)
        }
    }

    func scheduleMaintenanceTasks() {
        scheduleVacuumTask()
        scheduleAnalyzeTask()
        scheduleCleanupTask()
    }

    private func scheduleVacuumTask() {
        let request = BGProcessingTaskRequest(identifier: Self.vacuumTaskIdentifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 7 * 24 * 60 * 60) // 1 week
        request.requiresNetworkConnectivity = false
        request.requiresExternalPower = true

        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            print("Failed to schedule vacuum task: \(error)")
        }
    }

    private func scheduleAnalyzeTask() {
        let request = BGProcessingTaskRequest(identifier: Self.analyzeTaskIdentifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 24 * 60 * 60) // 1 day
        request.requiresNetworkConnectivity = false
        request.requiresExternalPower = false

        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            print("Failed to schedule analyze task: \(error)")
        }
    }

    private func scheduleCleanupTask() {
        let request = BGProcessingTaskRequest(identifier: Self.cleanupTaskIdentifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 24 * 60 * 60) // 1 day
        request.requiresNetworkConnectivity = false
        request.requiresExternalPower = false

        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            print("Failed to schedule cleanup task: \(error)")
        }
    }

    // MARK: - Background Task Handlers

    private func handleVacuumTask(task: BGProcessingTask) {
        task.expirationHandler = {
            task.setTaskCompleted(success: false)
        }

        Task {
            let success = await performVacuum()
            task.setTaskCompleted(success: success)
            scheduleVacuumTask() // Reschedule for next time
        }
    }

    private func handleAnalyzeTask(task: BGProcessingTask) {
        task.expirationHandler = {
            task.setTaskCompleted(success: false)
        }

        Task {
            let success = await performAnalyze()
            task.setTaskCompleted(success: success)
            scheduleAnalyzeTask() // Reschedule for next time
        }
    }

    private func handleCleanupTask(task: BGProcessingTask) {
        task.expirationHandler = {
            task.setTaskCompleted(success: false)
        }

        Task {
            let success = await performCleanup()
            task.setTaskCompleted(success: success)
            scheduleCleanupTask() // Reschedule for next time
        }
    }

    // MARK: - Maintenance Operations

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

    func performVacuum() async -> Bool {
        guard let storeURL = coreDataStack.persistentContainer.persistentStoreDescriptions.first?.url else {
            return false
        }

        do {
            let db = try SQLiteDatabase(path: storeURL.path)
            try db.execute("VACUUM")
            print("Database vacuum completed successfully")
            return true
        } catch {
            print("Database vacuum failed: \(error)")
            return false
        }
    }

    func performAnalyze() async -> Bool {
        guard let storeURL = coreDataStack.persistentContainer.persistentStoreDescriptions.first?.url else {
            return false
        }

        do {
            let db = try SQLiteDatabase(path: storeURL.path)
            try db.execute("ANALYZE")
            print("Database analyze completed successfully")
            return true
        } catch {
            print("Database analyze failed: \(error)")
            return false
        }
    }

    func performCleanup() async -> Bool {
        let context = coreDataStack.newBackgroundContext()

        return await context.perform {
            do {
                // Cleanup old messages (older than 90 days)
                let oldMessageDate = Date().addingTimeInterval(-90 * 24 * 60 * 60)
                let oldMessageRequest = NSFetchRequest<NSFetchRequestResult>(entityName: "Message")
                oldMessageRequest.predicate = NSPredicate(format: "internalDate < %@", oldMessageDate as NSDate)

                let deleteOldMessages = NSBatchDeleteRequest(fetchRequest: oldMessageRequest)
                deleteOldMessages.resultType = .resultTypeCount

                let oldMessageResult = try context.execute(deleteOldMessages) as? NSBatchDeleteResult
                print("Deleted \(oldMessageResult?.result ?? 0) old messages")

                // Cleanup orphaned attachments
                let orphanedAttachmentRequest = NSFetchRequest<NSFetchRequestResult>(entityName: "Attachment")
                orphanedAttachmentRequest.predicate = NSPredicate(format: "message == nil")

                let deleteOrphaned = NSBatchDeleteRequest(fetchRequest: orphanedAttachmentRequest)
                deleteOrphaned.resultType = .resultTypeCount

                let orphanedResult = try context.execute(deleteOrphaned) as? NSBatchDeleteResult
                print("Deleted \(orphanedResult?.result ?? 0) orphaned attachments")

                // Cleanup empty conversations
                let emptyConversationRequest = NSFetchRequest<NSFetchRequestResult>(entityName: "Conversation")
                emptyConversationRequest.predicate = NSPredicate(format: "messages.@count == 0")

                let deleteEmpty = NSBatchDeleteRequest(fetchRequest: emptyConversationRequest)
                deleteEmpty.resultType = .resultTypeCount

                let emptyResult = try context.execute(deleteEmpty) as? NSBatchDeleteResult
                print("Deleted \(emptyResult?.result ?? 0) empty conversations")

                // Save changes
                try self.coreDataStack.save(context: context)
                return true
            } catch {
                print("Database cleanup failed: \(error)")
                return false
            }
        }
    }

    func rebuildIndexes() async -> Bool {
        guard let storeURL = coreDataStack.persistentContainer.persistentStoreDescriptions.first?.url else {
            return false
        }

        do {
            let db = try SQLiteDatabase(path: storeURL.path)
            try db.execute("REINDEX")
            print("Database reindex completed successfully")
            return true
        } catch {
            print("Database reindex failed: \(error)")
            return false
        }
    }

    // MARK: - Denormalization Operations

    func updateDenormalizedFields() async {
        let context = coreDataStack.newBackgroundContext()

        await context.perform {
            // Update conversation message counts
            let conversationRequest = Conversation.fetchRequest()
            guard let conversations = try? context.fetch(conversationRequest) else { return }

            for conversation in conversations {
                // Update unread count
                let unreadMessages = (conversation.messages as? NSSet)?
                    .compactMap { $0 as? Message }
                    .filter { $0.isUnread }
                    .count ?? 0
                conversation.inboxUnreadCount = Int32(unreadMessages)

                // These fields would be added to Core Data model for production
                // For now, we just update the fields that exist
            }

            // Save denormalized data
            self.coreDataStack.saveIfNeeded(context: context)
            print("Denormalized fields updated successfully")
        }
    }

    // MARK: - Statistics

    func getDatabaseStatistics() async -> DatabaseStatistics {
        let context = coreDataStack.newBackgroundContext()

        let stats = await context.perform {
            let messageCount = (try? context.count(for: Message.fetchRequest())) ?? 0
            let conversationCount = (try? context.count(for: Conversation.fetchRequest())) ?? 0
            let attachmentCount = (try? context.count(for: Attachment.fetchRequest())) ?? 0
            let personCount = (try? context.count(for: Person.fetchRequest())) ?? 0

            // Calculate database size
            var databaseSize: Int64 = 0
            if let storeURL = self.coreDataStack.persistentContainer.persistentStoreDescriptions.first?.url {
                let fileManager = FileManager.default
                if let attributes = try? fileManager.attributesOfItem(atPath: storeURL.path) {
                    databaseSize = attributes[.size] as? Int64 ?? 0
                }
            }

            return (
                messageCount: messageCount,
                conversationCount: conversationCount,
                attachmentCount: attachmentCount,
                personCount: personCount,
                databaseSize: databaseSize
            )
        }

        return DatabaseStatistics(
            messageCount: stats.messageCount,
            conversationCount: stats.conversationCount,
            attachmentCount: stats.attachmentCount,
            personCount: stats.personCount,
            databaseSize: stats.databaseSize,
            lastMaintenanceDate: self.lastMaintenanceDate
        )
    }

    // MARK: - Persistence

    private func loadLastMaintenanceDate() {
        lastMaintenanceDate = UserDefaults.standard.object(forKey: "LastDatabaseMaintenance") as? Date
    }

    private func saveLastMaintenanceDate() {
        UserDefaults.standard.set(lastMaintenanceDate, forKey: "LastDatabaseMaintenance")
    }
}

// MARK: - Database Statistics
struct DatabaseStatistics {
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