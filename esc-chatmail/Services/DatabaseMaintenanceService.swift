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
    private let taskRegistry = BackgroundTaskRegistry.shared

    private init() {
        registerBackgroundTasks()
        loadLastMaintenanceDate()
    }

    // MARK: - Background Task Registration (Consolidated)

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
            Log.info("Database vacuum completed successfully", category: .coreData)
            return true
        } catch {
            Log.error("Database vacuum failed", category: .coreData, error: error)
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
            Log.info("Database analyze completed successfully", category: .coreData)
            return true
        } catch {
            Log.error("Database analyze failed", category: .coreData, error: error)
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
                oldMessageRequest.predicate = MessagePredicates.olderThan(oldMessageDate)

                let deleteOldMessages = NSBatchDeleteRequest(fetchRequest: oldMessageRequest)
                deleteOldMessages.resultType = .resultTypeCount

                let oldMessageResult = try context.execute(deleteOldMessages) as? NSBatchDeleteResult
                Log.debug("Deleted \(oldMessageResult?.result ?? 0) old messages", category: .coreData)

                // Cleanup orphaned attachments
                let orphanedAttachmentRequest = NSFetchRequest<NSFetchRequestResult>(entityName: "Attachment")
                orphanedAttachmentRequest.predicate = AttachmentPredicates.orphaned

                let deleteOrphaned = NSBatchDeleteRequest(fetchRequest: orphanedAttachmentRequest)
                deleteOrphaned.resultType = .resultTypeCount

                let orphanedResult = try context.execute(deleteOrphaned) as? NSBatchDeleteResult
                Log.debug("Deleted \(orphanedResult?.result ?? 0) orphaned attachments", category: .coreData)

                // Cleanup empty conversations
                let emptyConversationRequest = NSFetchRequest<NSFetchRequestResult>(entityName: "Conversation")
                emptyConversationRequest.predicate = ConversationPredicates.emptyMessages

                let deleteEmpty = NSBatchDeleteRequest(fetchRequest: emptyConversationRequest)
                deleteEmpty.resultType = .resultTypeCount

                let emptyResult = try context.execute(deleteEmpty) as? NSBatchDeleteResult
                Log.debug("Deleted \(emptyResult?.result ?? 0) empty conversations", category: .coreData)

                // Save changes
                try self.coreDataStack.save(context: context)
                return true
            } catch {
                Log.error("Database cleanup failed", category: .coreData, error: error)
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
            Log.info("Database reindex completed successfully", category: .coreData)
            return true
        } catch {
            Log.error("Database reindex failed", category: .coreData, error: error)
            return false
        }
    }

    // MARK: - Denormalization Operations

    func updateDenormalizedFields() async {
        let context = coreDataStack.newBackgroundContext()

        await context.perform {
            // Update conversation message counts
            let conversationRequest = Conversation.fetchRequest()

            let conversations: [Conversation]
            do {
                conversations = try context.fetch(conversationRequest)
            } catch {
                Log.error("Failed to fetch conversations for denormalization", category: .coreData, error: error)
                return
            }

            for conversation in conversations {
                // Update unread count
                let unreadMessages = (conversation.messages as? NSSet)?
                    .compactMap { $0 as? Message }
                    .filter { $0.isUnread }
                    .count ?? 0
                conversation.inboxUnreadCount = Int32(unreadMessages)
            }

            // Save denormalized data
            self.coreDataStack.saveIfNeeded(context: context)
            Log.info("Denormalized fields updated successfully", category: .coreData)
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
