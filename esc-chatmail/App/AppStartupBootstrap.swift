import Foundation

/// Set once fresh-install handling has succeeded in this process, so the
/// foreground retry loop does not re-run it on every attempt.
@MainActor
private var hasHandledFreshInstallThisProcess = false

/// Set once an attempt has touched the lazy persistent container. Later
/// attempts (this loop's, or a foreground launch joining after a cold BGTask
/// attempt failed) must reload explicitly: the container loads only once.
@MainActor
private var hasStartedStoreLoadThisProcess = false

@MainActor
private func prepareProductionAppPersistence() async -> Bool {
    if !hasHandledFreshInstallThisProcess {
        guard await FreshInstallHandler().checkAndHandleFreshInstall() else {
            return false
        }
        hasHandledFreshInstallThisProcess = true
        // Fresh-install (or installation-ID mismatch) cleanup, when it ran,
        // removed the whole defaults domain, including the Version row
        // App.init just published for the Settings app, and nothing else
        // rewrites it in this process. The write is skipped when the value is
        // unchanged.
        SettingsAppAccountPublisher.shared.publishAppVersion()
    }

    // Start loading only after fresh-install cleanup has had a chance to reset
    // persistent state, then wait before exposing the store to either
    // foreground services or background sync.
    if hasStartedStoreLoadThisProcess {
        CoreDataStack.shared.retryLoadAfterFailure()
    } else {
        hasStartedStoreLoadThisProcess = true
        _ = CoreDataStack.shared.persistentContainer
    }
    do {
        try await CoreDataStack.shared.waitForStoreToLoad(timeout: .infinity)
        AppLoadingModel.shared.clearStoreLoadFailure()
        return true
    } catch {
        Log.error("Core Data store failed to load", category: .coreData, error: error)
        AppLoadingModel.shared.showStoreLoadFailure(error)
        return false
    }
}

/// The process-wide services every entry into the app starts once persistence is ready
/// and before authentication is restored: what a sign-out or a fresh-install cleanup
/// renamed out of use and the last run did not finish removing is swept (in the
/// background, waited for by nothing), and `CacheCoordinator` starts hearing saves. Until
/// 2026-11-27 both ran from `initializeApp()`, which only `AppLoadingView`'s task runs,
/// so a background task's cold launch synced in a process where no save built a
/// reclamation plan: the bodies and attachments of the rows its sync deleted waited for
/// the daily orphan sweep, and leftover tombstones for the next foreground launch
/// (architecture review 2026-11, di-modularity#4, gap-change-propagation-pipeline#5).
/// The order is kept: persistence (the fresh-install check, then the store load), these,
/// then the restore, whose `reopenHTMLContent` closes `CacheCoordinator` first even at
/// cold launch and so expects it started. Never in the unit-test host, where the shared
/// coordinator would hear every test stack's save.
@MainActor
private func startProductionProcessServices() {
    guard !RuntimeEnvironment.isRunningUnitTests else { return }
    RetiredAccountDirectory.sweepLeftovers()
    CacheCoordinator.shared.start()
}

@MainActor
private func restoreProductionAuthentication() async -> AuthRestoreOutcome {
    await AuthSession.shared.restorePreviousSignIn()
}

/// Serializes the launch prerequisites shared by foreground startup and a cold
/// `BGTask` launch. Persistence is prepared before authentication restoration,
/// and both phases are single-flight so account cleanup/isolation cannot overlap
/// or run twice when foreground and background startup join the same launch.
actor AppStartupBootstrap {
    static let shared = AppStartupBootstrap()

    private struct ActivePreparation {
        let id: UUID
        let task: Task<Bool?, Never>
    }

    private struct ActiveAuthenticationRestore {
        let id: UUID
        let task: Task<AuthRestoreOutcome?, Never>
    }

    private let preparePersistenceOperation: @Sendable () async -> Bool
    private let startProcessServicesOperation: @Sendable () async -> Void
    private let restoreAuthenticationOperation: @Sendable () async -> AuthRestoreOutcome
    private var isPersistenceReady = false
    private var activePreparation: ActivePreparation?
    private var isAuthenticationRestored = false
    private var activeAuthenticationRestore: ActiveAuthenticationRestore?
    private var persistenceRetryWait: Task<Void, Never>?
    private var hasPendingPersistenceRetryRequest = false

    private init() {
        self.preparePersistenceOperation = {
            await prepareProductionAppPersistence()
        }
        self.startProcessServicesOperation = {
            await startProductionProcessServices()
        }
        self.restoreAuthenticationOperation = {
            await restoreProductionAuthentication()
        }
    }

    /// Test seam for pinning single-flight launch behavior without touching
    /// production credentials or persistence. The process services default to
    /// nothing: the production ones are the shared coordinator and the disk.
    init(
        preparePersistenceOperation: @escaping @Sendable () async -> Bool,
        restoreAuthenticationOperation: @escaping @Sendable () async -> AuthRestoreOutcome = {
            .terminalNoSession
        },
        startProcessServicesOperation: @escaping @Sendable () async -> Void = {}
    ) {
        self.preparePersistenceOperation = preparePersistenceOperation
        self.startProcessServicesOperation = startProcessServicesOperation
        self.restoreAuthenticationOperation = restoreAuthenticationOperation
    }

    func preparePersistenceIfNeeded() async -> Bool {
        if isPersistenceReady {
            return true
        }

        if let activePreparation {
            guard let succeeded = await awaitValueUnlessCancelled(
                of: activePreparation.task,
                cancellationValue: nil
            ) else {
                return false
            }
            finishPreparation(id: activePreparation.id, succeeded: succeeded)
            return succeeded
        }

        let preparationID = UUID()
        let preparePersistenceOperation = self.preparePersistenceOperation
        let startProcessServicesOperation = self.startProcessServicesOperation
        let task = Task<Bool?, Never> {
            guard await preparePersistenceOperation() else { return false }
            // Once per process: an attempt that succeeds is the last one, and a
            // waiter that is cancelled leaves this task running. Inside the single
            // flight, so a foreground launch joining a background one neither starts
            // the services twice nor restores authentication before they have started.
            await startProcessServicesOperation()
            return true
        }
        activePreparation = ActivePreparation(id: preparationID, task: task)

        guard let succeeded = await awaitValueUnlessCancelled(
            of: task,
            cancellationValue: nil
        ) else {
            return false
        }
        finishPreparation(id: preparationID, succeeded: succeeded)
        return succeeded
    }

    /// Keeps foreground startup alive across transient preparation failures.
    /// Background tasks use the single-attempt API above so they can fail fast
    /// within their system budget; SwiftUI's loading task instead retries until
    /// persistence is ready or that view task is cancelled.
    ///
    /// The wait between attempts doubles up to `maximumRetryDelayNanoseconds`:
    /// each attempt reloads a store whose load failed, and a store that failed
    /// for lack of space would otherwise re-run its migration every second.
    /// `requestPersistenceRetry()` ends a wait early.
    func preparePersistenceUntilReady(
        retryDelayNanoseconds: UInt64 = 1_000_000_000,
        maximumRetryDelayNanoseconds: UInt64 = 60_000_000_000
    ) async -> Bool {
        var retryDelay = min(retryDelayNanoseconds, maximumRetryDelayNanoseconds)
        while !Task.isCancelled {
            if await preparePersistenceIfNeeded() {
                return true
            }
            guard await waitForPersistenceRetry(nanoseconds: retryDelay) else {
                return false
            }
            retryDelay = retryDelay > maximumRetryDelayNanoseconds / 2
                ? maximumRetryDelayNanoseconds
                : retryDelay * 2
        }
        return false
    }

    /// Ends the foreground loop's current wait early, e.g. when the user taps
    /// Try Again after freeing space. A request that arrives while an attempt
    /// is running makes the next wait return at once.
    func requestPersistenceRetry() {
        guard let persistenceRetryWait else {
            hasPendingPersistenceRetryRequest = true
            return
        }
        persistenceRetryWait.cancel()
    }

    /// Returns false only when the calling task was cancelled.
    private func waitForPersistenceRetry(nanoseconds: UInt64) async -> Bool {
        if hasPendingPersistenceRetryRequest {
            hasPendingPersistenceRetryRequest = false
            return !Task.isCancelled
        }

        let wait = Task<Void, Never> {
            _ = await Task.sleepUnlessCancelled(nanoseconds: nanoseconds)
        }
        persistenceRetryWait = wait
        await withTaskCancellationHandler {
            await wait.value
        } onCancel: {
            wait.cancel()
        }
        persistenceRetryWait = nil
        return !Task.isCancelled
    }

    func restoreAuthenticationIfNeeded() async -> Bool {
        guard await preparePersistenceIfNeeded() else {
            return false
        }
        if isAuthenticationRestored {
            return true
        }

        if let activeAuthenticationRestore {
            guard let outcome = await awaitValueUnlessCancelled(
                of: activeAuthenticationRestore.task,
                cancellationValue: nil
            ) else {
                return false
            }
            finishAuthenticationRestore(
                id: activeAuthenticationRestore.id,
                outcome: outcome
            )
            return true
        }

        let restorationID = UUID()
        let restoreAuthenticationOperation = self.restoreAuthenticationOperation
        let task = Task<AuthRestoreOutcome?, Never> {
            await restoreAuthenticationOperation()
        }
        activeAuthenticationRestore = ActiveAuthenticationRestore(
            id: restorationID,
            task: task
        )

        guard let outcome = await awaitValueUnlessCancelled(
            of: task,
            cancellationValue: nil
        ) else {
            return false
        }
        finishAuthenticationRestore(id: restorationID, outcome: outcome)
        return true
    }

    func prepareForBackgroundSync() async -> Bool {
        await restoreAuthenticationIfNeeded()
    }

    private func finishPreparation(id: UUID, succeeded: Bool) {
        guard activePreparation?.id == id else { return }
        activePreparation = nil
        isPersistenceReady = succeeded
    }

    private func finishAuthenticationRestore(id: UUID, outcome: AuthRestoreOutcome) {
        guard activeAuthenticationRestore?.id == id else { return }
        activeAuthenticationRestore = nil
        isAuthenticationRestored = outcome.isComplete
    }
}
