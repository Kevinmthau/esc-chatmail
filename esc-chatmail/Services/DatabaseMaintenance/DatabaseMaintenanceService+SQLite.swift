import Foundation
import SQLite3

// MARK: - SQLite Operations

extension DatabaseMaintenanceService {

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
}
