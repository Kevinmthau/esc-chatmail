import Foundation

@MainActor
protocol ForegroundSyncPerforming: AnyObject {
    func triggerIncrementalSyncIfPossible() async -> ForegroundSyncRequestResult
    func waitForCurrentSyncToComplete() async
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
    private var deferredSyncTaskID: UUID?
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
            triggerSync(reason: reason, force: startedPeriodicLoop)
        }

        return startedPeriodicLoop
    }

    func stop(reason: String) {
        periodicTask?.cancel()
        periodicTask = nil
        deferredSyncTask?.cancel()
        deferredSyncTask = nil
        deferredSyncTaskID = nil
        log.debug("Foreground sync stopped (\(reason))")
    }

    func triggerSync(reason: String, force: Bool = false) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            _ = await self.requestSyncIfNeeded(reason: reason, force: force)
        }
    }

    func triggerSyncAfterCurrent(reason: String, force: Bool = false) {
        deferredSyncTask?.cancel()
        let taskID = UUID()
        deferredSyncTaskID = taskID
        deferredSyncTask = Task { @MainActor [weak self] in
            guard let self else { return }

            defer {
                if self.deferredSyncTaskID == taskID {
                    self.deferredSyncTask = nil
                    self.deferredSyncTaskID = nil
                }
            }

            while !Task.isCancelled {
                await self.syncEngine.waitForCurrentSyncToComplete()
                if Task.isCancelled {
                    return
                }

                let outcome = await self.requestSyncIfNeeded(reason: reason, force: force)
                if outcome != .alreadyInProgress {
                    return
                }
            }
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

    private enum SyncTriggerOutcome: Equatable {
        case started
        case alreadyInProgress
        case skipped
    }

    private func requestSyncIfNeeded(reason: String, force: Bool) async -> SyncTriggerOutcome {
        guard authSession.isAuthenticated else {
            log.debug("Skipping foreground sync (\(reason)): user not authenticated")
            return .skipped
        }

        if !force,
           let lastSyncTriggerAt,
           Date().timeIntervalSince(lastSyncTriggerAt) < minimumSyncGap {
            log.debug("Skipping foreground sync (\(reason)): throttled")
            return .skipped
        }

        switch await syncEngine.triggerIncrementalSyncIfPossible() {
        case .started:
            lastSyncTriggerAt = Date()
            return .started
        case .alreadyInProgress:
            log.debug("Skipping foreground sync (\(reason)): sync already in progress")
            return .alreadyInProgress
        case .skippedNoNetwork:
            log.debug("Skipping foreground sync (\(reason)): network unavailable")
            return .skipped
        }
    }
}
