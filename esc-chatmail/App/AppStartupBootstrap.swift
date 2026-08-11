import Foundation

@MainActor
private func prepareProductionAppPersistence() async -> Bool {
    guard await FreshInstallHandler().checkAndHandleFreshInstall() else {
        return false
    }

    // Start loading only after fresh-install cleanup has had a chance to reset
    // persistent state, then wait before exposing the store to either
    // foreground services or background sync.
    _ = CoreDataStack.shared.persistentContainer
    do {
        try await CoreDataStack.shared.waitForStoreToLoad(timeout: .infinity)
        return true
    } catch {
        Log.error("Core Data store failed to load", category: .coreData, error: error)
        return false
    }
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
    private let restoreAuthenticationOperation: @Sendable () async -> AuthRestoreOutcome
    private var isPersistenceReady = false
    private var activePreparation: ActivePreparation?
    private var isAuthenticationRestored = false
    private var activeAuthenticationRestore: ActiveAuthenticationRestore?

    private init() {
        self.preparePersistenceOperation = {
            await prepareProductionAppPersistence()
        }
        self.restoreAuthenticationOperation = {
            await restoreProductionAuthentication()
        }
    }

    /// Test seam for pinning single-flight launch behavior without touching
    /// production credentials or persistence.
    init(
        preparePersistenceOperation: @escaping @Sendable () async -> Bool,
        restoreAuthenticationOperation: @escaping @Sendable () async -> AuthRestoreOutcome = {
            .terminalNoSession
        }
    ) {
        self.preparePersistenceOperation = preparePersistenceOperation
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
        let task = Task<Bool?, Never> {
            await preparePersistenceOperation()
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
    func preparePersistenceUntilReady(
        retryDelayNanoseconds: UInt64 = 1_000_000_000
    ) async -> Bool {
        while !Task.isCancelled {
            if await preparePersistenceIfNeeded() {
                return true
            }
            guard await Task.sleepUnlessCancelled(
                nanoseconds: retryDelayNanoseconds
            ) else {
                return false
            }
        }
        return false
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
