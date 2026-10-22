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
    /// True when the injected container still needs its stores loaded through
    /// the production load and recovery ladder.
    private let injectedContainerNeedsLoading: Bool

    init() {
        self.injectedContainerForTesting = nil
        self.injectedContainerNeedsLoading = false
    }

    /// Creates a stack backed by an existing, already-loaded container so that
    /// services requiring a concrete `CoreDataStack` can run against isolated
    /// per-test storage instead of the shared on-disk store. Unit tests that
    /// operate on `CoreDataStack.shared` mutate state that is visible to every
    /// other test in the same runner process and leak async Core Data work
    /// across test boundaries.
    init(persistentContainerForTesting container: NSPersistentContainer) {
        self.injectedContainerForTesting = container
        self.injectedContainerNeedsLoading = false
        self._isStoreLoaded = true
    }

#if DEBUG
    /// Test-only: backs the stack with a container whose stores have not been
    /// loaded, so the first `persistentContainer` access runs the production
    /// load and recovery ladder against it.
    init(unloadedPersistentContainerForTesting container: NSPersistentContainer) {
        self.injectedContainerForTesting = container
        self.injectedContainerNeedsLoading = true
    }
#endif

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

    /// Test-only: forces the store-loaded flag so readiness gating (pending /
    /// slow-load branches) can be exercised without loading a real store.
    func debugSetStoreLoadedForTesting(_ loaded: Bool) {
        setStoreLoaded(loaded)
    }
#endif

    lazy var persistentContainer: NSPersistentContainer = {
        if let injectedContainerForTesting {
            if injectedContainerNeedsLoading {
                loadPersistentStores(for: injectedContainerForTesting)
            }
            return injectedContainerForTesting
        }

        let container = NSPersistentContainer(name: "ESCChatmail")

        // Configure for automatic migration
        let description = container.persistentStoreDescriptions.first
        description?.shouldMigrateStoreAutomatically = true
        description?.shouldInferMappingModelAutomatically = true

        // History tracking stays on (turning it off after a store has opened
        // with it logs a fault) even though nothing consumes history tokens;
        // DatabaseMaintenanceService purges old transactions during cleanup.
        // Remote-change notifications are NOT requested: nothing in the app
        // observes .NSPersistentStoreRemoteChange.
        description?.setOption(true as NSNumber, forKey: NSPersistentHistoryTrackingKey)

        loadPersistentStores(for: container)

        container.viewContext.automaticallyMergesChangesFromParent = true
        container.viewContext.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
        return container
    }()

    // NOTE: a runtime `enforceUniquenessConstraints` mutation lived here from
    // 2026-02 to 2026-07. It was born a no-op — the Message.id constraint has
    // been declared in the versioned .xcdatamodel since v1 (2025-09) — but it
    // was a latent landmine: had the declared constraint ever left the model,
    // the runtime append would have made every production store's metadata
    // match no bundled model, and the next model version would have wiped
    // upgrading stores via the recovery ladder. Deleted with model v3. Model
    // changes belong in versioned .xcdatamodel files only; never mutate the
    // loaded model at runtime. ModelConstraintMetadataTests pins the declared
    // constraints.

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
                guard await Task.sleepUnlessCancelled(nanoseconds: UInt64(delay * 1_000_000_000)) else { return }
                self?.retryLoadingStore(for: container)
            }

        case .migrationRecovery:
            attemptMigrationRecovery(for: container, originalError: error)

        case .storeReset:
            attemptStoreReset(for: container, originalError: error)

        case .keepStore:
            setStoreLoadError(PersistentStoreLoadError(classifying: error))
        }
    }

    /// Reloads the persistent store after a latched load failure, e.g. once
    /// the user has freed space or the device has unlocked. The container is
    /// lazy and loads once per process, so before this a latched error lasted
    /// until the app was killed and launch spun forever. No-op unless a load
    /// error is latched and no store is attached; callers touch
    /// `persistentContainer` first, so this never doubles the initial load.
    func retryLoadAfterFailure() {
        let container = persistentContainer
        guard storeLoadError != nil,
              container.persistentStoreCoordinator.persistentStores.isEmpty else {
            return
        }
        Log.info("Retrying Core Data store load after a latched failure", category: .coreData)
        resetStoreLoadTracking()
        loadPersistentStores(for: container)
    }

    private func retryLoadingStore(for container: NSPersistentContainer) {
        loadPersistentStores(for: container)
    }

    private func attemptMigrationRecovery(for container: NSPersistentContainer, originalError: NSError) {
        guard let storeURL = container.persistentStoreDescriptions.first?.url else {
            setStoreLoadError(PersistentStoreLoadError(classifying: originalError))
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
            setStoreLoadError(PersistentStoreLoadError(classifying: originalError))
            return
        }

        if recoveryHandler.prepareStoreReset(for: storeURL) {
            loadPersistentStores(for: container)
        } else {
            // The backup could not be written (often a full disk), so the
            // store stays and the load can be retried.
            setStoreLoadError(PersistentStoreLoadError(classifying: originalError))
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

    func newBackgroundContext() -> NSManagedObjectContext {
        let context = persistentContainer.newBackgroundContext()
        context.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
        return context
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

        // The container's viewContext outlives the store swap, so it still
        // holds objects registered against the destroyed store plus a
        // PersonFactory userInfo cache pointing at them. Drop both on the
        // fresh store; without this, the next sign-in's optimistic send
        // resurrected cached Persons as unfulfillable faults. Deliberately
        // done AFTER the store is back — placing this main-queue hop between
        // destroyAllData and the reload would widen the window in which the
        // coordinator has no stores, which un-quiesced background sync work
        // (IncrementalSyncOrchestrator fetches without gating on readiness)
        // could fetch/save into and trap on "no persistent stores".
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
        let viewContext = persistentContainer.viewContext
        await viewContext.perform {
            viewContext.reset()
            // reset() deregisters objects but leaves userInfo intact, so the
            // factory cache must be dropped explicitly.
            PersonFactory.resetCache(in: viewContext)
        }
    }
}
