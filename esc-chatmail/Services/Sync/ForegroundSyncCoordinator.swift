import Foundation

/// Coordinates foreground incremental sync independently of view lifecycle.
/// Runs while the app is active and authenticated.
@MainActor
final class ForegroundSyncCoordinator {
    static let shared = ForegroundSyncCoordinator()

    private let syncEngine: SyncEngine
    private let authSession: AuthSession
    private let periodicInterval: TimeInterval
    private let minimumSyncGap: TimeInterval
    private let log = LogCategory.sync.logger

    private var periodicTask: Task<Void, Never>?
    private var lastSyncTriggerAt: Date?

    init(
        syncEngine: SyncEngine? = nil,
        authSession: AuthSession? = nil,
        periodicInterval: TimeInterval = 120,
        minimumSyncGap: TimeInterval = 90
    ) {
        self.syncEngine = syncEngine ?? .shared
        self.authSession = authSession ?? .shared
        self.periodicInterval = periodicInterval
        self.minimumSyncGap = minimumSyncGap
    }

    func start(reason: String, triggerImmediateSync: Bool) {
        guard authSession.isAuthenticated else {
            log.debug("Foreground sync not started (\(reason)): user not authenticated")
            stop(reason: "notAuthenticated")
            return
        }

        startPeriodicLoopIfNeeded()

        if triggerImmediateSync {
            triggerSyncIfNeeded(reason: reason, force: true)
        }
    }

    func stop(reason: String) {
        periodicTask?.cancel()
        periodicTask = nil
        log.debug("Foreground sync stopped (\(reason))")
    }

    func triggerSync(reason: String, force: Bool = false) {
        triggerSyncIfNeeded(reason: reason, force: force)
    }

    private func startPeriodicLoopIfNeeded() {
        guard periodicTask == nil else { return }

        periodicTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: UInt64((self?.periodicInterval ?? 120) * 1_000_000_000))
                } catch {
                    break
                }

                guard let self else { break }
                self.triggerSync(reason: "foregroundPeriodic")
            }
        }

        log.debug("Foreground sync periodic loop started")
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
