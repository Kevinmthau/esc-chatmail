import Foundation
import CoreData

/// CoreDataStack uses @unchecked Sendable because:
/// - destroyAndReloadSync() requires synchronous semaphore-based coordination for fresh installs
/// - newBackgroundContext() and save() must remain synchronous for critical Core Data paths
/// - DispatchQueue (isolationQueue) provides thread safety for mutable state (_loadAttempts, _isStoreLoaded, _storeLoadError)
///
/// Future consideration: Create a companion CoreDataStackActor for async-only operations
final class CoreDataStack: @unchecked Sendable {
    static let shared = CoreDataStack()

    // Synchronize access to mutable state using serial queue
    private let isolationQueue = DispatchQueue(label: "com.esc.coreDataStack.isolation")
    private var _loadAttempts = 0

    private var _isStoreLoaded = false
    private var _storeLoadError: Error?

    // Extracted services
    private let recoveryHandler = CoreDataRecoveryHandler()

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
                Log.info("Core Data store loaded successfully: \(storeDescription)", category: .coreData)
            }
        }
    }

    private func handleStoreLoadError(_ error: NSError, for container: NSPersistentContainer) {
        loadAttempts += 1

        let result = recoveryHandler.handleError(error, currentAttempts: loadAttempts)

        switch result {
        case .retry(let delay):
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                self?.retryLoadingStore(for: container)
            }

        case .migrationRecovery:
            attemptMigrationRecovery(for: container)

        case .storeReset:
            attemptStoreReset(for: container)
        }
    }

    private func retryLoadingStore(for container: NSPersistentContainer) {
        loadPersistentStores(for: container)
    }

    private func attemptMigrationRecovery(for container: NSPersistentContainer) {
        guard let storeURL = container.persistentStoreDescriptions.first?.url else { return }

        if recoveryHandler.prepareMigrationRecovery(for: storeURL) {
            loadPersistentStores(for: container)
        } else {
            attemptStoreReset(for: container)
        }
    }

    private func attemptStoreReset(for container: NSPersistentContainer) {
        guard let storeURL = container.persistentStoreDescriptions.first?.url else { return }

        if recoveryHandler.prepareStoreReset(for: storeURL) {
            loadPersistentStores(for: container)
        } else {
            recoveryHandler.notifyUserOfCriticalError(
                storeLoadError ?? NSError(domain: "CoreData", code: -1, userInfo: [NSLocalizedDescriptionKey: "Unknown error"])
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

    func save(context: NSManagedObjectContext, retryCount: Int = CoreDataConfig.maxSaveRetries) throws {
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
                    } else if CoreDataErrorClassifier.isTransientError(error) && attempt < retryCount - 1 {
                        // Wait before retry for transient errors
                        Thread.sleep(forTimeInterval: 0.1 * Double(attempt + 1))
                        context.rollback()
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
                    Log.warning("Validation error for object: \(object.entity.name ?? "unknown")", category: .coreData)
                    // Optionally reset invalid objects
                    context.refresh(object, mergeChanges: false)
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
                    try CoreDataBackupManager.removeStore(at: storeURL)
                }
            } catch {
                errors.append(error)
                Log.error("Failed to destroy Core Data store", category: .coreData, error: error)
            }
        }

        // Reset state
        setStoreLoaded(false)
        loadAttempts = 0

        if !errors.isEmpty {
            throw CoreDataError.persistentFailure(errors.first!)
        }
    }

    /// Destroys all data and reloads the persistent stores synchronously.
    /// Use this for fresh install cleanup where you need to ensure stores are ready before continuing.
    func destroyAndReloadSync() throws {
        try destroyAllData()

        // Reset the viewContext to clear any stale managed objects
        persistentContainer.viewContext.reset()

        // Reload stores synchronously using a semaphore
        let semaphore = DispatchSemaphore(value: 0)
        var loadError: Error?

        persistentContainer.loadPersistentStores { [weak self] storeDescription, error in
            if let error = error {
                loadError = error
                Log.error("Failed to reload Core Data store", category: .coreData, error: error)
            } else {
                self?.setStoreLoaded(true)
                self?.loadAttempts = 0
                Log.info("Core Data store reloaded successfully: \(storeDescription)", category: .coreData)
            }
            semaphore.signal()
        }

        // Wait for stores to load (with timeout)
        let result = semaphore.wait(timeout: .now() + 10.0)
        if result == .timedOut {
            throw CoreDataError.storeLoadFailed(NSError(domain: "CoreDataStack", code: -1, userInfo: [NSLocalizedDescriptionKey: "Timed out waiting for store to reload"]))
        }

        if let error = loadError {
            throw CoreDataError.persistentFailure(error as NSError)
        }

        // Reset viewContext again after stores are loaded to ensure clean state
        persistentContainer.viewContext.reset()
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

    func resetStore() async throws {
        // Safely reset the store
        try destroyAllData()

        // Reinitialize
        loadPersistentStores(for: persistentContainer)

        // Wait for store to be ready
        try await waitForStoreToLoad()
    }
}
