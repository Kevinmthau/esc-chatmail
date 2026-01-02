import Foundation
import CoreData

/// Handles recovery operations for Core Data store loading failures.
final class CoreDataRecoveryHandler {
    private let retryDelay: TimeInterval
    private let maxLoadAttempts: Int

    init(retryDelay: TimeInterval = CoreDataConfig.retryDelay,
         maxLoadAttempts: Int = CoreDataConfig.maxLoadAttempts) {
        self.retryDelay = retryDelay
        self.maxLoadAttempts = maxLoadAttempts
    }

    /// Handles a store load error and returns the appropriate recovery action.
    /// - Parameters:
    ///   - error: The error that occurred during store loading
    ///   - currentAttempts: Number of attempts already made
    /// - Returns: The recovery action to take
    func handleError(_ error: NSError, currentAttempts: Int) -> RecoveryResult {
        let action = CoreDataErrorClassifier.recommendedAction(
            for: error,
            currentAttempts: currentAttempts,
            maxAttempts: maxLoadAttempts
        )

        switch action {
        case .retry:
            Log.warning("Core Data load attempt \(currentAttempts) failed with recoverable error: \(error)", category: .coreData)
            return .retry(delay: retryDelay)

        case .migrationRecovery:
            Log.error("Core Data migration failed", category: .coreData, error: error)
            return .migrationRecovery

        case .storeReset:
            Log.error("Core Data critical error", category: .coreData, error: error)
            return .storeReset
        }
    }

    /// Attempts migration recovery by backing up and removing the problematic store.
    /// - Parameter storeURL: The URL of the store to recover
    /// - Returns: true if recovery preparation succeeded
    func prepareMigrationRecovery(for storeURL: URL) -> Bool {
        do {
            // Create timestamped backup before attempting recovery
            let backupURL = try CoreDataBackupManager.createTimestampedBackup(at: storeURL)
            Log.info("Created backup before migration recovery: \(backupURL.path)", category: .coreData)

            // Remove problematic store
            try CoreDataBackupManager.removeStore(at: storeURL)
            return true
        } catch {
            Log.error("Migration recovery preparation failed", category: .coreData, error: error)
            return false
        }
    }

    /// Attempts store reset by backing up and removing the problematic store.
    /// - Parameter storeURL: The URL of the store to reset
    /// - Returns: true if reset preparation succeeded
    func prepareStoreReset(for storeURL: URL) -> Bool {
        do {
            // Create timestamped backup before destroying data
            let backupURL = try CoreDataBackupManager.createTimestampedBackup(at: storeURL)
            Log.info("Created backup before store reset: \(backupURL.path)", category: .coreData)

            // Remove problematic store
            try CoreDataBackupManager.removeStore(at: storeURL)
            return true
        } catch {
            Log.error("Store reset preparation failed", category: .coreData, error: error)
            return false
        }
    }

    /// Notifies the user of a critical error that couldn't be recovered.
    /// - Parameter error: The error to report
    func notifyUserOfCriticalError(_ error: Error) {
        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: NSNotification.Name("CoreDataCriticalError"),
                object: nil,
                userInfo: ["error": CoreDataError.persistentFailure(error)]
            )
        }
    }

    // MARK: - Result Types

    enum RecoveryResult {
        case retry(delay: TimeInterval)
        case migrationRecovery
        case storeReset
    }
}
