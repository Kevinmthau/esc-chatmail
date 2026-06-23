import Foundation
import SQLite3

// MARK: - SQLite Operations

extension DatabaseMaintenanceService {

    func performVacuum() async -> Bool {
        guard let storeURL = coreDataStack.persistentContainer.persistentStoreDescriptions.first?.url else {
            return false
        }

        return await StoreMaintenanceCoordinator.shared.runWhenStoreIsIdle(operationName: "database vacuum") {
            await Self.performSQLiteCommand("VACUUM", storeURL: storeURL, successMessage: "Database vacuum completed successfully", failureMessage: "Database vacuum failed")
        }
    }

    func performAnalyze() async -> Bool {
        guard let storeURL = coreDataStack.persistentContainer.persistentStoreDescriptions.first?.url else {
            return false
        }

        return await StoreMaintenanceCoordinator.shared.runWhenStoreIsIdle(operationName: "database analyze") {
            await Self.performSQLiteCommand("ANALYZE", storeURL: storeURL, successMessage: "Database analyze completed successfully", failureMessage: "Database analyze failed")
        }
    }

    func rebuildIndexes() async -> Bool {
        guard let storeURL = coreDataStack.persistentContainer.persistentStoreDescriptions.first?.url else {
            return false
        }

        return await StoreMaintenanceCoordinator.shared.runWhenStoreIsIdle(operationName: "database reindex") {
            await Self.performSQLiteCommand("REINDEX", storeURL: storeURL, successMessage: "Database reindex completed successfully", failureMessage: "Database reindex failed")
        }
    }

    nonisolated private static func performSQLiteCommand(
        _ command: String,
        storeURL: URL,
        successMessage: String,
        failureMessage: String
    ) async -> Bool {
        await Task.detached {
            do {
                let db = try SQLiteDatabase(path: storeURL.path)
                try db.execute(command)
                Log.info(successMessage, category: .coreData)
                return true
            } catch {
                Log.error(failureMessage, category: .coreData, error: error)
                return false
            }
        }.value
    }
}
