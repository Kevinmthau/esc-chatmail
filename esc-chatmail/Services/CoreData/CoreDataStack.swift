import Foundation
import CoreData

/// CoreDataStack uses @unchecked Sendable because:
/// - newBackgroundContext() and save() must remain synchronous for critical Core Data paths
/// - DispatchQueue (isolationQueue) provides thread safety for mutable state (_loadAttempts, _isStoreLoaded,
///   _storeLoadError, _isStoreLoadInFlight, _isContainerCreated, _loadWaiters)
///
/// Future consideration: Create a companion CoreDataStackActor for async-only operations
///
/// The production store is added asynchronously (`shouldAddStoreAsynchronously`), so a
/// load, and any migration it runs, happens off the main thread, and the readiness gate
/// is `waitForStoreToLoad`, never the first touch of `persistentContainer`. At most one
/// load is in flight (`_isStoreLoadInFlight`): it is claimed when a load starts and
/// released when the load attaches the store, latches an error or schedules a timed
/// retry. Reset Mailbox takes the same claim for its removal, so it refuses while a load
/// runs and no load can start while it removes the files. The unit-test host keeps the
/// synchronous add: its tests expect the shared store attached once the app has
/// initialized.
final class CoreDataStack: @unchecked Sendable {
    static let shared = CoreDataStack()

    // Synchronize access to mutable state using serial queue
    private let isolationQueue = DispatchQueue(label: "com.esc.coreDataStack.isolation")
    private var _loadAttempts = 0

    private var _isStoreLoaded = false
    private var _storeLoadError: Error?
    private var _deterministicReloadPermitted = false
    /// A load is running (or a corrupt-store reset is carrying one into its
    /// reload), or Reset Mailbox is removing the store. No second load starts
    /// while it is set, and Reset Mailbox refuses.
    private var _isStoreLoadInFlight = false
    /// Whether `persistentContainer` has been created, which starts its first
    /// load. Fresh-install cleanup removes the store by path, unloaded, while
    /// it is not (`removeStoreForFreshInstall()`).
    private var _isContainerCreated = false
    /// `waitForStoreToLoad` callers, answered when the store attaches or a
    /// load error is latched, or by their own timeout or cancellation.
    private var _loadWaiters: [UUID: CheckedContinuation<Void, Error>] = [:]

    // Extracted services
    private let recoveryHandler = CoreDataRecoveryHandler()

    /// Testing seam: when set, this container (typically in-memory) backs the
    /// stack instead of the production SQLite container.
    private let injectedContainerForTesting: NSPersistentContainer?
    /// True when the injected container still needs its stores loaded through
    /// the production load and recovery ladder.
    private let injectedContainerNeedsLoading: Bool
    /// `StoreVolumeFreeSpace.availableBytes()`, injectable so tests do not
    /// depend on the host's free space. Read only by
    /// `resetStoreAfterLoadFailure()`.
    private let availableStorageBytes: @Sendable () -> Int64?
    /// This build's model ordinal (`StoreModelCompatibility.currentModelOrdinal`),
    /// stamped into the store after a load and read after a migration-family
    /// load error.
    private let currentModelOrdinal: @Sendable () -> Int?
    /// Records, before a recovery reset removes the store, that it did
    /// (`StoreRecoveryResetMarker`), so the restore that follows can tell the
    /// store's own account's orphaned files from another account's.
    private let markStoreRemovedByRecovery: @Sendable () -> Void

    init() {
        self.injectedContainerForTesting = nil
        self.injectedContainerNeedsLoading = false
        self.availableStorageBytes = { StoreVolumeFreeSpace.availableBytes() }
        self.currentModelOrdinal = { StoreModelCompatibility.currentModelOrdinal() }
        self.markStoreRemovedByRecovery = { StoreRecoveryResetMarker.mark(in: .standard) }
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
        self.availableStorageBytes = { StoreVolumeFreeSpace.availableBytes() }
        self.currentModelOrdinal = { StoreModelCompatibility.currentModelOrdinal() }
        self.markStoreRemovedByRecovery = {}
        self._isStoreLoaded = true
        self._isContainerCreated = true
    }

#if DEBUG
    /// Test-only: backs the stack with a container whose stores have not been
    /// loaded, so the first `persistentContainer` access runs the production
    /// load and recovery ladder against it.
    init(
        unloadedPersistentContainerForTesting container: NSPersistentContainer,
        availableStorageBytes: @escaping @Sendable () -> Int64? = { StoreVolumeFreeSpace.availableBytes() },
        currentModelOrdinal: @escaping @Sendable () -> Int? = { StoreModelCompatibility.currentModelOrdinal() },
        markStoreRemovedByRecovery: @escaping @Sendable () -> Void = {}
    ) {
        self.injectedContainerForTesting = container
        self.injectedContainerNeedsLoading = true
        self.availableStorageBytes = availableStorageBytes
        self.currentModelOrdinal = currentModelOrdinal
        self.markStoreRemovedByRecovery = markStoreRemovedByRecovery
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

    /// Marks the store loaded, ends the load's in-flight claim and answers
    /// every waiter.
    private func setStoreLoaded(_ loaded: Bool) {
        #if DEBUG
        dispatchPrecondition(condition: .notOnQueue(isolationQueue))
        #endif
        let waiters: [CheckedContinuation<Void, Error>] = isolationQueue.sync {
            _isStoreLoaded = loaded
            guard loaded else { return [] }
            _storeLoadError = nil
            _isStoreLoadInFlight = false
            return removeAllLoadWaitersOnIsolationQueue()
        }
        for waiter in waiters {
            waiter.resume()
        }
    }

    /// Latches a load error, ends the load's in-flight claim and fails every
    /// waiter with it.
    private func setStoreLoadError(_ error: Error?) {
        #if DEBUG
        dispatchPrecondition(condition: .notOnQueue(isolationQueue))
        #endif
        let waiters: [CheckedContinuation<Void, Error>] = isolationQueue.sync {
            _isStoreLoaded = false
            _storeLoadError = error
            _isStoreLoadInFlight = false
            guard error != nil else { return [] }
            return removeAllLoadWaitersOnIsolationQueue()
        }
        guard let error else { return }
        for waiter in waiters {
            waiter.resume(throwing: CoreDataError.storeLoadFailed(error))
        }
    }

    /// Call only on `isolationQueue`.
    private func removeAllLoadWaitersOnIsolationQueue() -> [CheckedContinuation<Void, Error>] {
        let waiters = Array(_loadWaiters.values)
        _loadWaiters.removeAll()
        return waiters
    }

    /// Claims the one load that may be in flight. False while another load
    /// (or Reset Mailbox's removal) holds it.
    private func claimStoreLoad() -> Bool {
        #if DEBUG
        dispatchPrecondition(condition: .notOnQueue(isolationQueue))
        #endif
        return isolationQueue.sync {
            guard !_isStoreLoadInFlight else { return false }
            _isStoreLoadInFlight = true
            return true
        }
    }

    /// Ends an in-flight claim that neither attached the store nor latched an
    /// error: a timed retry is scheduled, or Reset Mailbox's removal is over.
    private func releaseStoreLoadClaim() {
        #if DEBUG
        dispatchPrecondition(condition: .notOnQueue(isolationQueue))
        #endif
        isolationQueue.sync { _isStoreLoadInFlight = false }
    }

    /// Whether a load (or Reset Mailbox's removal) is in flight.
    var isStoreLoadInFlight: Bool {
        #if DEBUG
        dispatchPrecondition(condition: .notOnQueue(isolationQueue))
        #endif
        return isolationQueue.sync { _isStoreLoadInFlight }
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

    /// Test-only: holds the in-flight claim as a running load would, so a
    /// test can ask what refuses while one runs.
    func debugClaimStoreLoadForTesting() -> Bool {
        claimStoreLoad()
    }

    func debugReleaseStoreLoadClaimForTesting() {
        releaseStoreLoadClaim()
    }

    /// Test-only: how many `waitForStoreToLoad` callers are still waiting.
    var debugPendingLoadWaiterCount: Int {
        isolationQueue.sync { _loadWaiters.count }
    }
#endif

    /// The store's data-protection class, written out on iOS (architecture review 2026-11,
    /// `security-privacy#6`): complete until the first unlock after a restart, which is Core Data's
    /// own default, so this changes nothing on a device today. The keychain names its class at
    /// every write (`TokenManager`, for locked-device background sync), and the store had none of
    /// its own: a Data Protection capability added to the target later, whose default is Complete,
    /// would have locked the store away from every BGAppRefresh and BGProcessing run on a locked
    /// phone, and the load-failure policy would have latched those launches without a word.
    /// `PrivilegeDeclarationsTests` pins the option and the entitlement file. The key is not
    /// available on macOS, where the store has no protection classes.
    static func applyFileProtection(to description: NSPersistentStoreDescription?) {
        #if os(iOS)
        description?.setOption(
            FileProtectionType.completeUntilFirstUserAuthentication.rawValue as NSString,
            forKey: NSPersistentStoreFileProtectionKey
        )
        #endif
    }

    lazy var persistentContainer: NSPersistentContainer = {
        markContainerCreated()
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
        Self.applyFileProtection(to: description)

        #if os(macOS)
        // A Mac unit-test host must never open the default URL
        // (`makeUnitTestHostStoreURL()` says why).
        if RuntimeEnvironment.isRunningUnitTests {
            description?.url = CoreDataStack.makeUnitTestHostStoreURL()
        }
        #endif

        // History tracking stays on (turning it off after a store has opened
        // with it logs a fault) even though nothing consumes history tokens;
        // DatabaseMaintenanceService purges old transactions during cleanup.
        // Remote-change notifications are NOT requested: nothing in the app
        // observes .NSPersistentStoreRemoteChange.
        description?.setOption(true as NSNumber, forKey: NSPersistentHistoryTrackingKey)

        // Off the main thread: the first touch of this container is on the
        // main actor (`AppStartupBootstrap`), and a synchronous add ran the
        // whole load, and any migration of a large store, there. The gate is
        // `waitForStoreToLoad`. The unit-test host keeps the synchronous add,
        // because it touches the container in `App.init` so that the shared
        // store is attached before any test runs.
        description?.shouldAddStoreAsynchronously = !RuntimeEnvironment.isRunningUnitTests

        // Before the load starts, so that the main thread never asks the
        // coordinator for its view context while the add holds it.
        container.viewContext.automaticallyMergesChangesFromParent = true
        container.viewContext.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy

        loadPersistentStores(for: container)
        return container
    }()

    private func markContainerCreated() {
        #if DEBUG
        dispatchPrecondition(condition: .notOnQueue(isolationQueue))
        #endif
        isolationQueue.sync { _isContainerCreated = true }
    }

    /// The URL `NSPersistentContainer(name: "ESCChatmail")` gives its store,
    /// read without creating the container (which would load the model a
    /// second time). `CoreDataStackAsyncLoadTests` pins that the two agree.
    static let defaultStoreURL: URL = NSPersistentContainer.defaultDirectoryURL()
        .appendingPathComponent("ESCChatmail")
        .appendingPathExtension("sqlite")

    #if os(macOS)
    private static let unitTestHostStoreDirectoryPrefix = "UnitTestHostStore-"

    /// A store URL in a new directory under the temporary directory, for a
    /// stack created in a Mac unit-test host.
    ///
    /// A Mac test host is the app itself, launched in the app's own sandbox
    /// container (`~/Library/Containers/com.esc.inboxchat`), so the default
    /// store URL there is the mailbox of the Mac app the user runs. The host
    /// loads the shared stack at launch (`esc_chatmailApp.init`), and every
    /// `TestCoreDataStack` reads its model from it, so with the default URL
    /// each Mac test run opened that mailbox with this checkout's model. A
    /// newer model would migrate it in place, and the installed app, unable
    /// to open it afterwards, could not open the mailbox again until it was
    /// updated (`PersistentStoreLoadError.storeFromNewerVersion`; before
    /// 2026-11 its recovery ladder deleted it). An older model would fail to
    /// open it in the same way.
    ///
    /// iOS keeps the default URL: a simulator's container holds nobody's mail.
    ///
    /// Directories left by earlier runs are swept first, best-effort. The
    /// sweep is age-gated, like `TestCoreDataStack`'s, so a host that is
    /// still running keeps its live store; a day, not an hour, because a
    /// directory's modification date does not move while its store is only
    /// written to. If the directory cannot be created the load fails; it
    /// never falls back to the default URL.
    private static func makeUnitTestHostStoreURL() -> URL {
        let fileManager = FileManager.default
        let temporaryDirectory = fileManager.temporaryDirectory

        let cutoff = Date().addingTimeInterval(-24 * 60 * 60)
        let entries = (try? fileManager.contentsOfDirectory(
            at: temporaryDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey]
        )) ?? []
        for url in entries where url.lastPathComponent.hasPrefix(unitTestHostStoreDirectoryPrefix) {
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            if modified < cutoff {
                try? fileManager.removeItem(at: url)
            }
        }

        let directory = temporaryDirectory.appendingPathComponent(
            unitTestHostStoreDirectoryPrefix + UUID().uuidString,
            isDirectory: true
        )
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("ESCChatmail.sqlite")
    }
    #endif

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

    /// Starts a load through the recovery ladder unless one is already in
    /// flight, whose outcome then answers every waiter.
    private func loadPersistentStores(for container: NSPersistentContainer) {
        guard claimStoreLoad() else {
            Log.debug("A store load is already in flight; not starting another", category: .coreData)
            return
        }
        startClaimedStoreLoad(for: container)
    }

    /// Loads with the in-flight claim already held. The completion runs on a
    /// background queue when the store is added asynchronously, and on the
    /// caller's thread otherwise; it ends the claim by attaching the store,
    /// latching an error or scheduling a timed retry, and a corrupt-store
    /// reset carries it into its reload.
    private func startClaimedStoreLoad(for container: NSPersistentContainer) {
        container.loadPersistentStores { [weak self] storeDescription, error in
            guard let self = self else { return }

            if let error = error as NSError? {
                self.handleStoreLoadError(error, for: container)
            } else {
                self.stampCurrentModelOrdinal(on: container, storeURL: storeDescription.url)
                self.loadAttempts = 0
                self.setStoreLoaded(true)
                Log.info("Core Data store loaded successfully: \(storeDescription)", category: .coreData)
                if let storeURL = storeDescription.url {
                    CoreDataBackupManager.pruneBackups(for: storeURL)
                }
            }
        }
    }

    /// Records in the store's metadata that this build's model opened it
    /// (`StoreModelCompatibility.modelOrdinalMetadataKey`), the evidence by
    /// which an older build tells it was saved by a newer one. The coordinator
    /// writes it with the next save.
    private func stampCurrentModelOrdinal(on container: NSPersistentContainer, storeURL: URL?) {
        let coordinator = container.persistentStoreCoordinator
        guard let storeURL, let store = coordinator.persistentStore(for: storeURL),
              let stamped = StoreModelCompatibility.metadataStamping(
                  currentModelOrdinal(),
                  into: coordinator.metadata(for: store)
              ) else {
            return
        }
        coordinator.setMetadata(stamped, for: store)
    }

    private func handleStoreLoadError(_ error: NSError, for container: NSPersistentContainer) {
        loadAttempts += 1

        let result = recoveryHandler.handleError(error, currentAttempts: loadAttempts)

        switch result {
        case .retry(let delay):
            // Nothing is in flight during the delay, and nothing is latched,
            // so Reset Mailbox still refuses and waiters keep waiting.
            releaseStoreLoadClaim()
            Task { @MainActor [weak self] in
                guard await Task.sleepUnlessCancelled(nanoseconds: UInt64(delay * 1_000_000_000)) else { return }
                self?.retryLoadingStore(for: container)
            }

        case .migrationFailed:
            // Kept, foreground or background: never backed up and deleted
            // here (`CoreDataErrorClassifier.RecoveryAction.migrationFailed`).
            setStoreLoadError(StoreModelCompatibility.loadError(
                forMigrationFailure: error,
                storeAt: container.persistentStoreDescriptions.first?.url,
                currentModelOrdinal: currentModelOrdinal()
            ))

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
    ///
    /// A latch that reloading cannot change (`isDeterministicLoadFailure`: a
    /// failed migration, a newer build's store) is reloaded only once the user
    /// has asked (`permitReloadAfterDeterministicFailure()`), not by the launch
    /// loop's timed retries or a background task: each reload runs the whole
    /// migration again before it fails the same way.
    ///
    /// Clearing the latch and claiming the load are one step, so no second
    /// load and no Reset Mailbox can start between them.
    func retryLoadAfterFailure() {
        let container = persistentContainer
        guard container.persistentStoreCoordinator.persistentStores.isEmpty else {
            return
        }
        switch claimReloadAfterFailure() {
        case .claimed:
            Log.info("Retrying Core Data store load after a latched failure", category: .coreData)
            startClaimedStoreLoad(for: container)
        case .nothingToRetry:
            return
        case .awaitingUserPermit:
            Log.debug("Not reloading a store whose migration cannot succeed until the user asks", category: .coreData)
        }
    }

    private enum ReloadClaim {
        case claimed
        /// No load error is latched, or a load or a reset is in flight.
        case nothingToRetry
        case awaitingUserPermit
    }

    private func claimReloadAfterFailure() -> ReloadClaim {
        #if DEBUG
        dispatchPrecondition(condition: .notOnQueue(isolationQueue))
        #endif
        return isolationQueue.sync {
            guard let loadError = _storeLoadError, !_isStoreLoadInFlight else {
                return .nothingToRetry
            }
            // Consumed by every retry, so a permit Try Again gave a retry that
            // did not need it is not left for a later timed one.
            let isPermitted = _deterministicReloadPermitted
            _deterministicReloadPermitted = false
            if Self.isDeterministicLoadFailure(loadError), !isPermitted {
                return .awaitingUserPermit
            }
            _isStoreLoaded = false
            _storeLoadError = nil
            _loadAttempts = 0
            _isStoreLoadInFlight = true
            return .claimed
        }
    }

    /// What `resetStoreAfterLoadFailure()` did.
    enum StoreResetOutcome: Equatable {
        /// The store was backed up and removed. `retryLoadAfterFailure()`
        /// then loads an empty one.
        case removed
        /// Nothing was touched: no resettable load failure
        /// (`allowsResetAfterLoadFailure`) is latched with the store detached, or the
        /// volume is low on space or could not be measured. The store opened, a timeout retry is pending, or
        /// the disk is (or may be) full.
        case notResettable
        /// The backup could not be written or the store could not be
        /// removed, so it was kept and the failure stays latched.
        case failed
    }

    /// Backs up and removes a store whose load failed and was kept, for the
    /// launch screen's Reset Mailbox once retrying has not helped
    /// (`AppLoadingPolicy`): a permanent error outside the classifier's reset
    /// allow-list otherwise strands the user on that screen. Goes through the
    /// same backup-then-remove path as a corrupt store; the caller then calls
    /// `retryLoadAfterFailure()`.
    ///
    /// Refuses unless a resettable failure (`allowsResetAfterLoadFailure`) is
    /// latched and no store is attached, so it never deletes an open store or
    /// one a timeout retry is about to load. Also refuses unless the volume measurably has
    /// `StoreVolumeFreeSpace.lowStorageThresholdBytes` free: a full disk
    /// usually latches `.unavailable` (SQLite reports CANTOPEN, not FULL), so
    /// the latched error alone cannot rule one out, and there freeing space
    /// keeps the data while a reset frees nothing. Loads now run off the main
    /// thread, so the main actor no longer keeps a load out of the removal:
    /// the reset takes the load's in-flight claim for it instead, and refuses
    /// while a load holds it.
    func resetStoreAfterLoadFailure() -> StoreResetOutcome {
        let container = persistentContainer
        guard let loadError = claimStoreForResetAfterLoadFailure() else {
            return .notResettable
        }
        // The latch stays: the retry that follows the removal reloads it.
        defer { releaseStoreLoadClaim() }
        guard container.persistentStoreCoordinator.persistentStores.isEmpty,
              let storeURL = container.persistentStoreDescriptions.first?.url,
              StoreVolumeFreeSpace.hasRoomForStoreReset(availableBytes: availableStorageBytes()) else {
            return .notResettable
        }
        // Deliberate data loss: the backup is the only copy of queued
        // PendingAction and OutboundSendMutationRecord rows.
        Log.error(
            "Resetting the store at the user's request; queued PendingAction/OutboundSendMutationRecord rows survive only in the backup",
            category: .coreData,
            error: loadError
        )
        // Before the removal: a crash between the two leaves a marker for a
        // store that is still there, which the restore treats as it treats
        // any store with rows. The removal is by path (the file, its -wal and
        // its -shm), so it also removes a store that never attached.
        markStoreRemovedByRecovery()
        guard recoveryHandler.prepareStoreReset(for: storeURL) else {
            return .failed
        }
        // The latched error describes the store just removed, so the next
        // retry must load the empty one, whoever asks for it.
        permitReloadAfterDeterministicFailure()
        return .removed
    }

    /// The latched error, with the in-flight claim taken so that no load can
    /// start until the reset is over. Nil, with nothing claimed, unless a
    /// resettable error is latched and no load is in flight.
    private func claimStoreForResetAfterLoadFailure() -> Error? {
        #if DEBUG
        dispatchPrecondition(condition: .notOnQueue(isolationQueue))
        #endif
        return isolationQueue.sync {
            guard let loadError = _storeLoadError,
                  Self.allowsResetAfterLoadFailure(loadError),
                  !_isStoreLoadInFlight else {
                return nil
            }
            _isStoreLoadInFlight = true
            return loadError
        }
    }

    /// Lets the next `retryLoadAfterFailure()` reload a deterministic latch.
    /// The launch screen's Try Again and Reset Mailbox call it.
    func permitReloadAfterDeterministicFailure() {
        #if DEBUG
        dispatchPrecondition(condition: .notOnQueue(isolationQueue))
        #endif
        isolationQueue.sync { _deterministicReloadPermitted = true }
    }

    /// Latched load errors that reloading the same store cannot change.
    static func isDeterministicLoadFailure(_ loadError: Error) -> Bool {
        switch loadError {
        case PersistentStoreLoadError.migrationFailed, PersistentStoreLoadError.storeFromNewerVersion:
            return true
        default:
            return false
        }
    }

    /// The latched load errors the launch screen's Reset Mailbox may remove
    /// the store for: every migration-class error, a store a newer build
    /// saved included (Kevin, 2026-11-24), and a store kept unopened. Never
    /// `.insufficientStorage`: freeing space keeps the data.
    static func allowsResetAfterLoadFailure(_ loadError: Error) -> Bool {
        switch loadError {
        case PersistentStoreLoadError.unavailable, PersistentStoreLoadError.migrationFailed,
             PersistentStoreLoadError.storeFromNewerVersion:
            return true
        default:
            return false
        }
    }

    private func retryLoadingStore(for container: NSPersistentContainer) {
        // A timed retry loads only a store that is still detached and
        // unlatched; anything else was settled by another load meanwhile.
        guard !isStoreLoaded, storeLoadError == nil,
              container.persistentStoreCoordinator.persistentStores.isEmpty else {
            return
        }
        loadPersistentStores(for: container)
    }

    /// Runs inside the failed load's completion, still holding its in-flight
    /// claim, which the reload carries on.
    private func attemptStoreReset(for container: NSPersistentContainer, originalError: NSError) {
        guard let storeURL = container.persistentStoreDescriptions.first?.url else {
            setStoreLoadError(PersistentStoreLoadError(classifying: originalError))
            return
        }

        markStoreRemovedByRecovery()
        if recoveryHandler.prepareStoreReset(for: storeURL) {
            startClaimedStoreLoad(for: container)
        } else {
            // The backup could not be written (often a full disk), so the
            // store stays and the load can be retried.
            setStoreLoadError(PersistentStoreLoadError(classifying: originalError))
        }
    }

    var viewContext: NSManagedObjectContext {
        persistentContainer.viewContext
    }

    /// Returns once the store is attached; throws `storeLoadFailed` with the
    /// latched error as soon as one is latched, with a timeout error after
    /// `timeout` seconds (`.infinity`: none), and `CancellationError` when the
    /// calling task is cancelled. Answered by the load itself, not by polling:
    /// a waiter registers here and `setStoreLoaded`/`setStoreLoadError` resume
    /// it. A store that is not loaded and has no load in flight is waited
    /// for all the same, as before: a retry may still start one.
    func waitForStoreToLoad(timeout: TimeInterval = 10) async throws {
        // The common case, on every background save's path.
        if isStoreLoaded { return }
        let waiterID = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                self.registerLoadWaiter(waiterID, continuation: continuation, timeout: timeout)
            }
        } onCancel: {
            self.resumeLoadWaiter(waiterID, throwing: CancellationError())
        }
    }

    private func registerLoadWaiter(
        _ waiterID: UUID,
        continuation: CheckedContinuation<Void, Error>,
        timeout: TimeInterval
    ) {
        #if DEBUG
        dispatchPrecondition(condition: .notOnQueue(isolationQueue))
        #endif
        let immediateOutcome: Result<Void, Error>? = isolationQueue.sync {
            if _isStoreLoaded {
                return .success(())
            }
            if let loadError = _storeLoadError {
                return .failure(CoreDataError.storeLoadFailed(loadError))
            }
            _loadWaiters[waiterID] = continuation
            return nil
        }
        if let immediateOutcome {
            continuation.resume(with: immediateOutcome)
            return
        }
        // Read after registering: a cancellation whose handler ran before the
        // waiter was registered found nothing to resume, and has set the flag
        // by then. Resuming removes the waiter first, so it resumes once.
        if Task.isCancelled {
            resumeLoadWaiter(waiterID, throwing: CancellationError())
            return
        }
        if let deadline = Self.loadWaitDeadline(after: timeout) {
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: deadline) {
                self.resumeLoadWaiter(
                    waiterID,
                    throwing: CoreDataError.storeLoadFailed(NSError(
                        domain: "CoreData",
                        code: -1,
                        userInfo: [NSLocalizedDescriptionKey: "Store load timeout"]
                    ))
                )
            }
        }
    }

    /// Resumes one waiter, if it is still waiting, with `error`.
    private func resumeLoadWaiter(_ waiterID: UUID, throwing error: Error) {
        #if DEBUG
        dispatchPrecondition(condition: .notOnQueue(isolationQueue))
        #endif
        let waiter = isolationQueue.sync { _loadWaiters.removeValue(forKey: waiterID) }
        waiter?.resume(throwing: error)
    }

    /// Nil for a timeout that is not finite (no timer). A finite one is
    /// capped at a year so that converting it to nanoseconds cannot overflow.
    static func loadWaitDeadline(after timeout: TimeInterval, now: DispatchTime = .now()) -> DispatchTime? {
        guard timeout.isFinite else { return nil }
        let seconds = min(max(timeout, 0), 365 * 24 * 60 * 60)
        return now + .nanoseconds(Int(seconds * 1_000_000_000))
    }

    /// Loads persistent stores asynchronously without blocking the main
    /// thread. Bypasses the recovery ladder, but not the in-flight claim: with
    /// a load already in flight it waits for that one instead.
    func loadStoresAsync() async throws {
        guard claimStoreLoad() else {
            try await waitForStoreToLoad(timeout: .infinity)
            return
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            persistentContainer.loadPersistentStores { [weak self] storeDescription, error in
                if let error = error {
                    self?.setStoreLoadError(error)
                    Log.error("Failed to load Core Data store async", category: .coreData, error: error)
                    continuation.resume(throwing: CoreDataError.storeLoadFailed(error))
                } else {
                    if let self {
                        self.stampCurrentModelOrdinal(on: self.persistentContainer, storeURL: storeDescription.url)
                    }
                    self?.loadAttempts = 0
                    self?.setStoreLoaded(true)
                    Log.info("Core Data store loaded successfully (async): \(storeDescription)", category: .coreData)
                    continuation.resume()
                }
            }
        }
    }

    /// Fresh-install cleanup of the store. Before the container exists (the
    /// launch's own first load comes after this cleanup) the store is removed
    /// by path, with its `-wal`, `-shm` and backups, and never opened: opening
    /// it first ran its migration, on the main thread until 2026-11, only to
    /// delete what it migrated. The launch's load then creates an empty one.
    /// If the container already exists, its store is destroyed and reloaded
    /// (`destroyAndReloadAsync()`).
    func removeStoreForFreshInstall() async throws {
        guard let storeURL = storeURLIfContainerNotCreated() else {
            try await destroyAndReloadAsync()
            return
        }
        if FileManager.default.fileExists(atPath: storeURL.path) {
            try CoreDataBackupManager.removeStore(at: storeURL)
        } else {
            // A store's journal files can outlive it; remove them anyway.
            try? FileManager.default.removeItem(atPath: storeURL.path + "-wal")
            try? FileManager.default.removeItem(atPath: storeURL.path + "-shm")
        }
        CoreDataBackupManager.removeAllBackups(for: storeURL)
        Log.info("Removed the store before its first load (fresh install)", category: .coreData)
    }

    /// The store's URL while `persistentContainer` has not been created, read
    /// without creating it; nil once it has been.
    private func storeURLIfContainerNotCreated() -> URL? {
        #if DEBUG
        dispatchPrecondition(condition: .notOnQueue(isolationQueue))
        #endif
        guard !isolationQueue.sync(execute: { _isContainerCreated }) else { return nil }
        if let injectedContainerForTesting {
            return injectedContainerForTesting.persistentStoreDescriptions.first?.url
        }
        #if os(macOS)
        // A Mac test host's store is not at the default URL, which there is
        // the mailbox of the Mac app the user runs
        // (`makeUnitTestHostStoreURL()`); never remove that by path.
        if RuntimeEnvironment.isRunningUnitTests {
            return nil
        }
        #endif
        return Self.defaultStoreURL
    }

    /// Destroys all data and reloads the persistent stores asynchronously without
    /// blocking the calling thread.
    func destroyAndReloadAsync() async throws {
        _ = persistentContainer
        if !isStoreLoaded {
            // No timeout: the store is added off the main thread, so a load
            // in flight here may be running a long migration, and a timeout
            // would leave the store this cleanup exists to remove.
            try await waitForStoreToLoad(timeout: .infinity)
        }

        try destroyAllData()
        addEmptyStoreSynchronously()

        // Reset the viewContext to clear any stale managed objects
        await resetViewContextState()

        // Reload stores asynchronously
        try await loadStoresAsync()

        // Reset viewContext again after stores are loaded to ensure clean state
        await resetViewContextState()
    }

    /// Makes the next add synchronous. After `destroyAllData()` the store
    /// being added is empty, so there is no migration to keep off the
    /// caller's thread, and an asynchronous add would leave the coordinator
    /// with no store for its whole duration, in which a save or a batch
    /// delete raises.
    private func addEmptyStoreSynchronously() {
        for description in persistentContainer.persistentStoreDescriptions {
            description.shouldAddStoreAsynchronously = false
        }
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

        // Backups from a reset are copies of this
        // mailbox too, so they go with it (sign-out, disconnect, fresh
        // install). Read from the descriptions, not the attached stores: the
        // loop above has detached them all, and a store that never opened was
        // never attached. Best-effort and not an error: nothing reads a backup
        // back, so one that survives cannot surface in the app, and
        // `pruneBackups` expires it.
        for storeURL in persistentContainer.persistentStoreDescriptions.compactMap(\.url) {
            CoreDataBackupManager.removeAllBackups(for: storeURL)
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

        // Reinitialize, synchronously (`addEmptyStoreSynchronously()`), so
        // the coordinator is without a store no longer than it was before
        // the launch's load moved off the main thread.
        addEmptyStoreSynchronously()
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
