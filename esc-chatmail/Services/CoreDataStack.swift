import Foundation
import CoreData

enum CoreDataError: LocalizedError {
    case storeLoadFailed(Error)
    case migrationFailed(Error)
    case saveFailed(Error)
    case transientFailure(Error)
    case persistentFailure(Error)
    case stackDestroyed

    var errorDescription: String? {
        switch self {
        case .storeLoadFailed(let error):
            return "Failed to load data store: \(error.localizedDescription)"
        case .migrationFailed(let error):
            return "Failed to migrate data: \(error.localizedDescription)"
        case .saveFailed(let error):
            return "Failed to save data: \(error.localizedDescription)"
        case .transientFailure(let error):
            return "Temporary data error: \(error.localizedDescription)"
        case .persistentFailure(let error):
            return "Critical data error: \(error.localizedDescription)"
        case .stackDestroyed:
            return "Data stack has been destroyed"
        }
    }

    var recoverySuggestion: String? {
        switch self {
        case .storeLoadFailed, .migrationFailed, .persistentFailure, .stackDestroyed:
            return "Please restart the app. If the problem persists, you may need to reinstall."
        case .saveFailed, .transientFailure:
            return "Please try again. Your data is safe."
        }
    }
}

final class CoreDataStack: @unchecked Sendable {
    static let shared = CoreDataStack()

    // Synchronize access to mutable state using serial queue
    private let isolationQueue = DispatchQueue(label: "com.esc.coreDataStack.isolation")
    private var _loadAttempts = 0
    private let maxLoadAttempts = 3
    private let retryDelay: TimeInterval = 2.0

    private var _isStoreLoaded = false
    private var _storeLoadError: Error?

    var isStoreLoaded: Bool {
        isolationQueue.sync { _isStoreLoaded }
    }

    private var loadAttempts: Int {
        get { isolationQueue.sync { _loadAttempts } }
        set { isolationQueue.sync { _loadAttempts = newValue } }
    }

    private var storeLoadError: Error? {
        get { isolationQueue.sync { _storeLoadError } }
        set { isolationQueue.sync { _storeLoadError = newValue } }
    }

    private func setStoreLoaded(_ loaded: Bool) {
        isolationQueue.sync { _isStoreLoaded = loaded }
    }

    lazy var persistentContainer: NSPersistentContainer = {
        let container = NSPersistentContainer(name: "ESCChatmail")

        // Configure for automatic migration
        let description = container.persistentStoreDescriptions.first
        description?.shouldMigrateStoreAutomatically = true
        description?.shouldInferMappingModelAutomatically = true

        // Set up options for better error recovery
        description?.setOption(true as NSNumber, forKey: NSPersistentHistoryTrackingKey)
        description?.setOption(true as NSNumber, forKey: NSPersistentStoreRemoteChangeNotificationPostOptionKey)

        loadPersistentStores(for: container)

        container.viewContext.automaticallyMergesChangesFromParent = true
        container.viewContext.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
        return container
    }()

    private func loadPersistentStores(for container: NSPersistentContainer) {
        container.loadPersistentStores { [weak self] storeDescription, error in
            guard let self = self else { return }

            if let error = error as NSError? {
                self.storeLoadError = error
                self.handleStoreLoadError(error, for: container)
            } else {
                self.setStoreLoaded(true)
                self.loadAttempts = 0
                print("Core Data store loaded successfully: \(storeDescription)")
            }
        }
    }

    private func handleStoreLoadError(_ error: NSError, for container: NSPersistentContainer) {
        loadAttempts += 1

        // Check if error is recoverable
        if isRecoverableError(error) && loadAttempts < maxLoadAttempts {
            print("Core Data load attempt \(loadAttempts) failed with recoverable error: \(error)")

            // Retry after delay
            DispatchQueue.main.asyncAfter(deadline: .now() + retryDelay) { [weak self] in
                self?.retryLoadingStore(for: container)
            }
        } else if isMigrationError(error) {
            // Attempt to recover from migration failure
            print("Core Data migration failed: \(error)")
            attemptMigrationRecovery(for: container, error: error)
        } else {
            // Non-recoverable error - attempt to reset store as last resort
            print("Core Data critical error: \(error)")
            attemptStoreReset(for: container, error: error)
        }
    }

    private func isRecoverableError(_ error: NSError) -> Bool {
        // Check for transient errors that might succeed on retry
        let recoverableCodes = [
            NSPersistentStoreTimeoutError,
            NSPersistentStoreIncompatibleVersionHashError,
            NSPersistentStoreSaveConflictsError
        ]
        return recoverableCodes.contains(error.code)
    }

    private func isMigrationError(_ error: NSError) -> Bool {
        let migrationCodes = [
            NSMigrationError,
            NSMigrationConstraintViolationError,
            NSMigrationCancelledError,
            NSMigrationMissingSourceModelError
        ]
        return migrationCodes.contains(error.code)
    }

    private func retryLoadingStore(for container: NSPersistentContainer) {
        loadPersistentStores(for: container)
    }

    private func createTimestampedBackup(at storeURL: URL) throws -> URL {
        let timestamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let backupURL = storeURL.deletingPathExtension().appendingPathExtension("backup-\(timestamp).sqlite")

        // Create backups directory if it doesn't exist
        let backupsDir = storeURL.deletingLastPathComponent().appendingPathComponent("Backups")
        try? FileManager.default.createDirectory(at: backupsDir, withIntermediateDirectories: true)

        let backupPath = backupsDir.appendingPathComponent(backupURL.lastPathComponent)

        // Copy main store file
        try FileManager.default.copyItem(at: storeURL, to: backupPath)

        // Copy associated SQLite files (-wal and -shm)
        let walURL = storeURL.appendingPathExtension("wal")
        let shmURL = storeURL.appendingPathExtension("shm")
        let backupWalURL = backupPath.appendingPathExtension("wal")
        let backupShmURL = backupPath.appendingPathExtension("shm")

        try? FileManager.default.copyItem(at: walURL, to: backupWalURL)
        try? FileManager.default.copyItem(at: shmURL, to: backupShmURL)

        print("Created timestamped backup at: \(backupPath)")
        return backupPath
    }

    private func attemptMigrationRecovery(for container: NSPersistentContainer, error: NSError) {
        // Try loading with manual migration
        if let storeURL = container.persistentStoreDescriptions.first?.url {
            do {
                // Create timestamped backup before attempting recovery
                let backupURL = try createTimestampedBackup(at: storeURL)
                print("Created backup before migration recovery: \(backupURL.path)")

                // Remove problematic store
                try FileManager.default.removeItem(at: storeURL)
                // Also remove journal files
                try? FileManager.default.removeItem(at: storeURL.appendingPathExtension("wal"))
                try? FileManager.default.removeItem(at: storeURL.appendingPathExtension("shm"))

                // Retry loading
                loadPersistentStores(for: container)
            } catch {
                print("Migration recovery failed: \(error)")
                attemptStoreReset(for: container, error: error)
            }
        }
    }

    private func attemptStoreReset(for container: NSPersistentContainer, error: Error) {
        // Last resort: delete and recreate store
        if let storeURL = container.persistentStoreDescriptions.first?.url {
            do {
                // Create timestamped backup before destroying data
                let backupURL = try createTimestampedBackup(at: storeURL)
                print("Created backup before store reset: \(backupURL.path)")

                // Remove problematic store
                try FileManager.default.removeItem(at: storeURL)
                // Also remove journal files
                try? FileManager.default.removeItem(at: storeURL.appendingPathExtension("wal"))
                try? FileManager.default.removeItem(at: storeURL.appendingPathExtension("shm"))

                loadPersistentStores(for: container)
            } catch {
                // Store is completely broken - notify user
                print("Store reset failed even after backup: \(error)")
                notifyUserOfCriticalError(error)
            }
        }
    }

    private func notifyUserOfCriticalError(_ error: Error) {
        // Post notification that views can observe to show alert
        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: NSNotification.Name("CoreDataCriticalError"),
                object: nil,
                userInfo: ["error": CoreDataError.persistentFailure(error)]
            )
        }
    }
    
    var viewContext: NSManagedObjectContext {
        persistentContainer.viewContext
    }

    func waitForStoreToLoad(timeout: TimeInterval = 10) async throws {
        let startTime = Date()

        while !isStoreLoaded {
            if Date().timeIntervalSince(startTime) > timeout {
                throw CoreDataError.storeLoadFailed(storeLoadError ?? NSError(domain: "CoreData", code: -1, userInfo: [NSLocalizedDescriptionKey: "Store load timeout"]))
            }

            try await Task.sleep(nanoseconds: 100_000_000) // 0.1 seconds
        }
    }
    
    func newBackgroundContext() -> NSManagedObjectContext {
        let context = persistentContainer.newBackgroundContext()
        context.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
        return context
    }
    
    func save(context: NSManagedObjectContext, retryCount: Int = 3) throws {
        try context.performAndWait {
            guard context.hasChanges else { return }

            var lastError: Error?

            for attempt in 0..<retryCount {
                do {
                    try context.save()
                    return // Success
                } catch let error as NSError {
                    lastError = error

                    // Handle specific Core Data errors
                    if error.code == NSManagedObjectMergeError {
                        // Resolve merge conflicts
                        handleMergeConflicts(in: context, error: error)
                    } else if error.code == NSValidationMultipleErrorsError {
                        // Handle validation errors
                        handleValidationErrors(in: context, error: error)
                    } else if isTransientError(error) && attempt < retryCount - 1 {
                        // Wait before retry for transient errors
                        Thread.sleep(forTimeInterval: 0.1 * Double(attempt + 1))
                        context.refreshAllObjects()
                    } else {
                        // Non-recoverable error
                        throw CoreDataError.saveFailed(error)
                    }
                }
            }

            if let error = lastError {
                throw CoreDataError.saveFailed(error)
            }
        }
    }

    private func isTransientError(_ error: NSError) -> Bool {
        // Errors that might succeed on retry
        let transientCodes = [
            NSManagedObjectConstraintMergeError,
            NSPersistentStoreSaveConflictsError,
            NSSQLiteError // SQLite busy errors
        ]
        return transientCodes.contains(error.code) || error.domain == NSSQLiteErrorDomain
    }

    private func handleMergeConflicts(in context: NSManagedObjectContext, error: NSError) {
        // Refresh objects involved in merge conflict
        if let conflicts = error.userInfo[NSPersistentStoreSaveConflictsErrorKey] as? [NSMergeConflict] {
            for conflict in conflicts {
                let sourceObject = conflict.sourceObject
                sourceObject.managedObjectContext?.refresh(sourceObject, mergeChanges: false)
            }
        }
    }

    private func handleValidationErrors(in context: NSManagedObjectContext, error: NSError) {
        // Log validation errors for debugging
        if let errors = error.userInfo[NSDetailedErrorsKey] as? [NSError] {
            for detailedError in errors {
                if let object = detailedError.userInfo[NSValidationObjectErrorKey] as? NSManagedObject {
                    print("Validation error for object: \(object)")
                    // Optionally reset invalid objects
                    context.refresh(object, mergeChanges: false)
                }
            }
        }
    }

    func saveAsync(context: NSManagedObjectContext) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            context.perform { [weak self] in
                guard let self = self else {
                    continuation.resume(throwing: CoreDataError.stackDestroyed)
                    return
                }
                do {
                    try self.save(context: context)
                    continuation.resume(returning: ())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
    
    func destroyAllData() throws {
        let coordinator = persistentContainer.persistentStoreCoordinator
        var errors: [Error] = []

        for store in coordinator.persistentStores {
            do {
                let storeURL = store.url
                try coordinator.remove(store)

                if let storeURL = storeURL {
                    try FileManager.default.removeItem(at: storeURL)

                    // Also remove the journal files (-wal and -shm files for SQLite)
                    let walURL = storeURL.appendingPathExtension("wal")
                    let shmURL = storeURL.appendingPathExtension("shm")
                    try? FileManager.default.removeItem(at: walURL)
                    try? FileManager.default.removeItem(at: shmURL)
                }
            } catch {
                errors.append(error)
                print("Failed to destroy Core Data store: \(error)")
            }
        }

        // Reset state
        setStoreLoaded(false)
        loadAttempts = 0

        if !errors.isEmpty {
            throw CoreDataError.persistentFailure(errors.first!)
        }
    }

    func performBackgroundTask<T>(_ block: @escaping (NSManagedObjectContext) throws -> T) async throws -> T {
        try await waitForStoreToLoad()

        return try await withCheckedThrowingContinuation { continuation in
            persistentContainer.performBackgroundTask { context in
                context.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
                do {
                    let result = try block(context)
                    continuation.resume(returning: result)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    // Convenience method for non-critical saves that logs errors but doesn't throw
    func saveIfNeeded(context: NSManagedObjectContext) {
        guard context.hasChanges else { return }

        do {
            try save(context: context)
        } catch {
            print("Core Data save error (non-critical): \(error)")
            // Log error but don't crash - suitable for UI updates and non-critical operations
        }
    }

    func resetStore() async throws {
        // Safely reset the store
        try destroyAllData()

        // Reinitialize
        loadPersistentStores(for: persistentContainer)

        // Wait for store to be ready
        try await waitForStoreToLoad()
    }
}