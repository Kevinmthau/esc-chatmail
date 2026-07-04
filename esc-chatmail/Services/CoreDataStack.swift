import Foundation
import CoreData

/// CoreDataStack uses @unchecked Sendable because:
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

    /// Testing seam: when set, this container (typically in-memory) backs the
    /// stack instead of the production SQLite container.
    private let injectedContainerForTesting: NSPersistentContainer?

    init() {
        self.injectedContainerForTesting = nil
    }

    /// Creates a stack backed by an existing, already-loaded container so that
    /// services requiring a concrete `CoreDataStack` can run against isolated
    /// per-test storage instead of the shared on-disk store. Unit tests that
    /// operate on `CoreDataStack.shared` mutate state that is visible to every
    /// other test in the same runner process and leak async Core Data work
    /// across test boundaries.
    init(persistentContainerForTesting container: NSPersistentContainer) {
        self.injectedContainerForTesting = container
        self._isStoreLoaded = true
    }

    var isStoreLoaded: Bool {
        // DEBUG-only check to catch potential deadlocks when calling from actor contexts
        #if DEBUG
        dispatchPrecondition(condition: .notOnQueue(isolationQueue))
        #endif
        return isolationQueue.sync { _isStoreLoaded }
    }

    private var loadAttempts: Int {
        get {
            #if DEBUG
            dispatchPrecondition(condition: .notOnQueue(isolationQueue))
            #endif
            return isolationQueue.sync { _loadAttempts }
        }
        set {
            #if DEBUG
            dispatchPrecondition(condition: .notOnQueue(isolationQueue))
            #endif
            isolationQueue.sync { _loadAttempts = newValue }
        }
    }

    private var storeLoadError: Error? {
        #if DEBUG
        dispatchPrecondition(condition: .notOnQueue(isolationQueue))
        #endif
        return isolationQueue.sync { _storeLoadError }
    }

    private var storeLoadState: (isLoaded: Bool, loadError: Error?) {
        #if DEBUG
        dispatchPrecondition(condition: .notOnQueue(isolationQueue))
        #endif
        return isolationQueue.sync {
            (isLoaded: _isStoreLoaded, loadError: _storeLoadError)
        }
    }

    private func setStoreLoaded(_ loaded: Bool) {
        #if DEBUG
        dispatchPrecondition(condition: .notOnQueue(isolationQueue))
        #endif
        isolationQueue.sync {
            _isStoreLoaded = loaded
            if loaded {
                _storeLoadError = nil
            }
        }
    }

    private func setStoreLoadError(_ error: Error?) {
        #if DEBUG
        dispatchPrecondition(condition: .notOnQueue(isolationQueue))
        #endif
        isolationQueue.sync {
            _isStoreLoaded = false
            _storeLoadError = error
        }
    }

    private func resetStoreLoadTracking() {
        #if DEBUG
        dispatchPrecondition(condition: .notOnQueue(isolationQueue))
        #endif
        isolationQueue.sync {
            _isStoreLoaded = false
            _storeLoadError = nil
            _loadAttempts = 0
        }
    }

#if DEBUG
    func debugSetStoreLoadErrorForTesting(_ error: Error) {
        setStoreLoadError(error)
    }
#endif

    lazy var persistentContainer: NSPersistentContainer = {
        if let injectedContainerForTesting {
            return injectedContainerForTesting
        }

        let container = NSPersistentContainer(name: "ESCChatmail")
        enforceUniquenessConstraints(in: container)

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

    private func enforceUniquenessConstraints(in container: NSPersistentContainer) {
        // Under unit tests this model instance is shared with the per-test
        // in-memory stacks (one model per process keeps +entity unambiguous),
        // and the test suite's fixtures rely on constraint-free semantics.
        if RuntimeEnvironment.isRunningUnitTests { return }

        guard let messageEntity = container.managedObjectModel.entitiesByName["Message"] else {
            Log.error("Missing Message entity for uniqueness constraints", category: .coreData)
            return
        }

        let constraint: [String] = ["id"]
        if messageEntity.uniquenessConstraints.contains(where: { ($0 as? [String]) == constraint }) {
            return
        }

        messageEntity.uniquenessConstraints.append(constraint as [Any])
        Log.info("Applied uniqueness constraint on Message.id", category: .coreData)
    }

    private func loadPersistentStores(for container: NSPersistentContainer) {
        container.loadPersistentStores { [weak self] storeDescription, error in
            guard let self = self else { return }

            if let error = error as NSError? {
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
            attemptMigrationRecovery(for: container, originalError: error)

        case .storeReset:
            attemptStoreReset(for: container, originalError: error)
        }
    }

    private func retryLoadingStore(for container: NSPersistentContainer) {
        loadPersistentStores(for: container)
    }

    private func attemptMigrationRecovery(for container: NSPersistentContainer, originalError: NSError) {
        guard let storeURL = container.persistentStoreDescriptions.first?.url else {
            setStoreLoadError(originalError)
            recoveryHandler.notifyUserOfCriticalError(originalError)
            return
        }

        if recoveryHandler.prepareMigrationRecovery(for: storeURL) {
            loadPersistentStores(for: container)
        } else {
            attemptStoreReset(for: container, originalError: originalError)
        }
    }

    private func attemptStoreReset(for container: NSPersistentContainer, originalError: NSError) {
        guard let storeURL = container.persistentStoreDescriptions.first?.url else {
            setStoreLoadError(originalError)
            recoveryHandler.notifyUserOfCriticalError(originalError)
            return
        }

        if recoveryHandler.prepareStoreReset(for: storeURL) {
            loadPersistentStores(for: container)
        } else {
            setStoreLoadError(originalError)
            recoveryHandler.notifyUserOfCriticalError(originalError)
        }
    }

    var viewContext: NSManagedObjectContext {
        persistentContainer.viewContext
    }

    func waitForStoreToLoad(timeout: TimeInterval = 10) async throws {
        let startTime = Date()

        while true {
            let state = storeLoadState
            if state.isLoaded {
                return
            }

            if let loadError = state.loadError {
                throw CoreDataError.storeLoadFailed(loadError)
            }

            if Date().timeIntervalSince(startTime) > timeout {
                throw CoreDataError.storeLoadFailed(storeLoadError ?? NSError(domain: "CoreData", code: -1, userInfo: [NSLocalizedDescriptionKey: "Store load timeout"]))
            }

            try await Task.sleep(nanoseconds: 100_000_000) // 0.1 seconds
        }
    }

    /// Loads persistent stores asynchronously without blocking the main thread.
    func loadStoresAsync() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            persistentContainer.loadPersistentStores { [weak self] storeDescription, error in
                if let error = error {
                    self?.setStoreLoadError(error)
                    Log.error("Failed to load Core Data store async", category: .coreData, error: error)
                    continuation.resume(throwing: CoreDataError.storeLoadFailed(error))
                } else {
                    self?.setStoreLoaded(true)
                    self?.loadAttempts = 0
                    Log.info("Core Data store loaded successfully (async): \(storeDescription)", category: .coreData)
                    continuation.resume()
                }
            }
        }
    }

    /// Destroys all data and reloads the persistent stores asynchronously without
    /// blocking the calling thread.
    func destroyAndReloadAsync() async throws {
        _ = persistentContainer
        if !isStoreLoaded {
            try await waitForStoreToLoad()
        }

        try destroyAllData()

        // Reset the viewContext to clear any stale managed objects
        await resetViewContextState()

        // Reload stores asynchronously
        try await loadStoresAsync()

        // Reset viewContext again after stores are loaded to ensure clean state
        await resetViewContextState()
    }

    /// Resets `viewContext` on its own queue to clear stale managed objects.
    ///
    /// `viewContext` is a main-queue context, so mutating it from a caller running
    /// off the main queue — e.g. `destroyAndReloadAsync()` invoked from
    /// `FreshInstallHandler` on a global-executor thread — is an undefined-behavior
    /// data race that traps under `-com.apple.CoreData.ConcurrencyDebug 1`. Routing
    /// the reset through `perform` guarantees it runs on the context's own queue.
    private func resetViewContextState() async {
        let viewContext = self.viewContext
        await viewContext.perform {
            viewContext.reset()
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
        resetStoreLoadTracking()

        if let firstError = errors.first {
            throw CoreDataError.persistentFailure(firstError)
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

    func resetStore() async throws {
        // Safely reset the store
        try destroyAllData()

        // Reinitialize
        loadPersistentStores(for: persistentContainer)

        // Wait for store to be ready
        try await waitForStoreToLoad()
    }
}
