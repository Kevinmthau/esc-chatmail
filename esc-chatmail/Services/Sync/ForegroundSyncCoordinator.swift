import Foundation

@MainActor
protocol ForegroundSyncPerforming: AnyObject {
    var isSyncing: Bool { get }
    func performIncrementalSync() async throws
}

@MainActor
protocol ForegroundSyncAuthenticationProviding: AnyObject {
    var isAuthenticated: Bool { get }
}

extension SyncEngine: ForegroundSyncPerforming {}
extension AuthSession: ForegroundSyncAuthenticationProviding {}

/// Coordinates foreground incremental sync independently of view lifecycle.
/// Runs while the app is active and authenticated.
@MainActor
final class ForegroundSyncCoordinator {
    static let shared = ForegroundSyncCoordinator()

    private let syncEngine: any ForegroundSyncPerforming
    private let authSession: any ForegroundSyncAuthenticationProviding
    private let periodicInterval: TimeInterval
    private let minimumSyncGap: TimeInterval
    private let log = LogCategory.sync.logger

    private var periodicTask: Task<Void, Never>?
    private var deferredSyncTask: Task<Void, Never>?
    private var lastSyncTriggerAt: Date?

    init(
        syncEngine: (any ForegroundSyncPerforming)? = nil,
        authSession: (any ForegroundSyncAuthenticationProviding)? = nil,
        periodicInterval: TimeInterval = 60,
        minimumSyncGap: TimeInterval = 30
    ) {
        self.syncEngine = syncEngine ?? SyncEngine.shared
        self.authSession = authSession ?? AuthSession.shared
        self.periodicInterval = periodicInterval
        self.minimumSyncGap = minimumSyncGap
    }

    @discardableResult
    func start(reason: String, triggerImmediateSync: Bool) -> Bool {
        guard authSession.isAuthenticated else {
            log.debug("Foreground sync not started (\(reason)): user not authenticated")
            stop(reason: "notAuthenticated")
            return false
        }

        let startedPeriodicLoop = startPeriodicLoopIfNeeded()

        if triggerImmediateSync {
            // Only force when we are starting a fresh foreground loop (e.g. cold launch or
            // returning from background). Repeated start() calls while already active should
            // respect the minimum gap to avoid duplicate launch syncs.
            triggerSyncIfNeeded(reason: reason, force: startedPeriodicLoop)
        }

        return startedPeriodicLoop
    }

    func stop(reason: String) {
        periodicTask?.cancel()
        periodicTask = nil
        deferredSyncTask?.cancel()
        deferredSyncTask = nil
        log.debug("Foreground sync stopped (\(reason))")
    }

    func triggerSync(reason: String, force: Bool = false) {
        triggerSyncIfNeeded(reason: reason, force: force)
    }

    func triggerSyncAfterCurrent(reason: String, force: Bool = false) {
        deferredSyncTask?.cancel()
        deferredSyncTask = Task { @MainActor [weak self] in
            guard let self else { return }

            while self.syncEngine.isSyncing {
                do {
                    try await Task.sleep(nanoseconds: 50_000_000)
                } catch {
                    return
                }
            }

            self.deferredSyncTask = nil
            self.triggerSyncIfNeeded(reason: reason, force: force)
        }
    }

    private func startPeriodicLoopIfNeeded() -> Bool {
        guard periodicTask == nil else { return false }

        periodicTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: UInt64((self?.periodicInterval ?? 60) * 1_000_000_000))
                } catch {
                    break
                }

                guard let self else { break }
                self.triggerSync(reason: "foregroundPeriodic")
            }
        }

        log.debug("Foreground sync periodic loop started")
        return true
    }

    private func triggerSyncIfNeeded(reason: String, force: Bool) {
        guard authSession.isAuthenticated else {
            log.debug("Skipping foreground sync (\(reason)): user not authenticated")
            return
        }

        guard !syncEngine.isSyncing else {
            log.debug("Skipping foreground sync (\(reason)): sync already in progress")
            return
        }

        if !force,
           let lastSyncTriggerAt,
           Date().timeIntervalSince(lastSyncTriggerAt) < minimumSyncGap {
            log.debug("Skipping foreground sync (\(reason)): throttled")
            return
        }

        lastSyncTriggerAt = Date()

        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.syncEngine.performIncrementalSync()
            } catch {
                self.log.error("Foreground sync failed (\(reason))", error: error)
            }
        }
    }
}
