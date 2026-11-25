import Foundation

// MARK: - SQLite Operations

extension DatabaseMaintenanceService {

    func performAnalyze() async -> Bool {
        let coreDataStack = self.coreDataStack
        return await storeMaintenanceCoordinator.runWhenStoreIsIdle(operationName: "database analyze") {
            // Read inside the run, where no reset can begin, and before
            // `persistentContainer`, whose first touch would start the store
            // load here, inside no bootstrap.
            guard coreDataStack.isStoreLoaded,
                  let storeURL = coreDataStack.persistentContainer.persistentStoreDescriptions.first?.url else {
                Log.info("Database analyze skipped: the store is not loaded", category: .coreData)
                return false
            }
            return await Self.performSQLiteCommand("ANALYZE", storeURL: storeURL, successMessage: "Database analyze completed successfully", failureMessage: "Database analyze failed")
        }
    }

    /// Runs one statement on a connection of its own, and stops it when the
    /// calling task is cancelled: a background task's expiration and a
    /// sign-out's quiescence both cancel the maintenance run this is called
    /// inside (`StoreMaintenanceCoordinator`).
    nonisolated private static func performSQLiteCommand(
        _ command: String,
        storeURL: URL,
        successMessage: String,
        failureMessage: String
    ) async -> Bool {
        do {
            let db = try SQLiteDatabase(path: storeURL.path)
            try await db.executeUnlessCancelled(command)
            Log.info(successMessage, category: .coreData)
            return true
        } catch SQLiteDatabase.DatabaseError.interrupted {
            Log.info("\(command) stopped: the maintenance run was cancelled", category: .coreData)
            return false
        } catch {
            Log.error(failureMessage, category: .coreData, error: error)
            return false
        }
    }
}
