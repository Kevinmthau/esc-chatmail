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

        case .migrationFailed:
            Log.error("Core Data migration failed; keeping the store on disk", category: .coreData, error: error)
            return .migrationFailed

        case .storeReset:
            Log.error("Core Data store is corrupt", category: .coreData, error: error)
            return .storeReset

        case .keepStore:
            Log.error("Core Data store could not be opened; keeping it on disk", category: .coreData, error: error)
            return .keepStore
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

    // MARK: - Result Types

    enum RecoveryResult {
        case retry(delay: TimeInterval)
        case migrationFailed
        case storeReset
        case keepStore
    }
}
