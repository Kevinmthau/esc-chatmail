import Foundation

@MainActor
protocol ForegroundSyncPerforming: AnyObject {
    func triggerIncrementalSyncIfPossible(
        completion: @escaping @MainActor @Sendable (Bool) -> Void
    ) async -> ForegroundSyncRequestResult
    func waitForCurrentSyncToComplete() async
}

@MainActor
protocol ForegroundSyncAuthenticationProviding: AnyObject {
    var canAccessMailbox: Bool { get }
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
    private let maxImmediateFollowUpRuns: Int
    private let log = LogCategory.sync.logger

    private var periodicTask: Task<Void, Never>?
    private var deferredSyncTask: Task<Void, Never>?
    private var deferredSyncTaskID: UUID?
    private var lastSyncTriggerAt: Date?

    init(
        syncEngine: (any ForegroundSyncPerforming)? = nil,
        authSession: (any ForegroundSyncAuthenticationProviding)? = nil,
        periodicInterval: TimeInterval = 60,
        minimumSyncGap: TimeInterval = 30,
        maxImmediateFollowUpRuns: Int = 3
    ) {
        self.syncEngine = syncEngine ?? SyncEngine.shared
        self.authSession = authSession ?? AuthSession.shared
        self.periodicInterval = periodicInterval
        self.minimumSyncGap = minimumSyncGap
        self.maxImmediateFollowUpRuns = max(0, maxImmediateFollowUpRuns)
    }

    @discardableResult
    func start(reason: String, triggerImmediateSync: Bool) -> Bool {
        guard authSession.canAccessMailbox else {
            log.debug("Foreground sync not started (\(reason)): mailbox unavailable")
            stop(reason: "mailboxUnavailable")
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
        triggerSync(
            reason: reason,
            force: force,
            remainingImmediateFollowUps: maxImmediateFollowUpRuns
        )
    }

    /// Routes post-send reconciliation through the app-scoped foreground
    /// scheduler so bounded history slices retain their continuation policy.
    func performIncrementalSync() async throws {
        let outcome = await requestSyncIfNeeded(
            reason: "postSend",
            force: true,
            remainingImmediateFollowUps: maxImmediateFollowUpRuns
        )
        if outcome == .alreadyInProgress {
            triggerSyncAfterCurrent(
                reason: "postSendAfterCurrent",
                force: true,
                remainingImmediateFollowUps: maxImmediateFollowUpRuns
            )
        }
    }

    private func triggerSync(
        reason: String,
        force: Bool,
        remainingImmediateFollowUps: Int
    ) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            let outcome = await self.requestSyncIfNeeded(
                reason: reason,
                force: force,
                remainingImmediateFollowUps: remainingImmediateFollowUps
            )
            if outcome == .alreadyInProgress {
                // Account transitions deliberately hold the shared boundary
                // until store validation/repair finishes. Preserve the
                // immediate auth/scene trigger across that short boundary (or
                // any real active run) instead of waiting for the next timer.
                self.triggerSyncAfterCurrent(
                    reason: "\(reason)AfterCurrent",
                    force: force,
                    remainingImmediateFollowUps: remainingImmediateFollowUps
                )
            }
        }
    }

    func triggerSyncAfterCurrent(reason: String, force: Bool = false) {
        triggerSyncAfterCurrent(
            reason: reason,
            force: force,
            remainingImmediateFollowUps: maxImmediateFollowUpRuns
        )
    }

    private func triggerSyncAfterCurrent(
        reason: String,
        force: Bool,
        remainingImmediateFollowUps: Int
    ) {
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

                let outcome = await self.requestSyncIfNeeded(
                    reason: reason,
                    force: force,
                    remainingImmediateFollowUps: remainingImmediateFollowUps
                )
                if outcome != .alreadyInProgress {
                    return
                }
            }
        }
    }

    func performUserInitiatedSync(reason: String) async {
        let outcome = await requestSyncIfNeeded(
            reason: reason,
            force: true,
            remainingImmediateFollowUps: maxImmediateFollowUpRuns
        )
        if outcome == .started {
            log.debug("User-initiated sync waiting for started run (\(reason))")
            await syncEngine.waitForCurrentSyncToComplete()
            return
        }

        guard outcome == .alreadyInProgress else { return }

        log.debug("User-initiated sync waiting for active run (\(reason))")
        await syncEngine.waitForCurrentSyncToComplete()
        guard !Task.isCancelled else { return }

        let retryOutcome = await requestSyncIfNeeded(
            reason: "\(reason)AfterCurrent",
            force: true,
            remainingImmediateFollowUps: maxImmediateFollowUpRuns
        )
        if retryOutcome == .started {
            log.debug("User-initiated sync waiting for started run (\(reason))")
            await syncEngine.waitForCurrentSyncToComplete()
        } else if retryOutcome == .alreadyInProgress {
            log.debug("Skipping queued user-initiated sync (\(reason)): sync still active")
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

    private func requestSyncIfNeeded(
        reason: String,
        force: Bool,
        remainingImmediateFollowUps: Int
    ) async -> SyncTriggerOutcome {
        guard authSession.canAccessMailbox else {
            log.debug("Skipping foreground sync (\(reason)): mailbox unavailable")
            return .skipped
        }

        if !force,
           let lastSyncTriggerAt,
           Date().timeIntervalSince(lastSyncTriggerAt) < minimumSyncGap {
            log.debug("Skipping foreground sync (\(reason)): throttled")
            return .skipped
        }

        switch await syncEngine.triggerIncrementalSyncIfPossible(
            completion: { [weak self] needsFollowUp in
                guard needsFollowUp else { return }
                self?.scheduleImmediateFollowUp(
                    after: reason,
                    remainingImmediateFollowUps: remainingImmediateFollowUps
                )
            }
        ) {
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

    private func scheduleImmediateFollowUp(
        after reason: String,
        remainingImmediateFollowUps: Int
    ) {
        guard authSession.canAccessMailbox, periodicTask != nil else {
            log.debug("Not scheduling foreground sync continuation outside an active session")
            return
        }
        guard remainingImmediateFollowUps > 0 else {
            log.warning("Foreground sync reached its immediate continuation limit; leaving durable progress for the periodic loop")
            return
        }

        triggerSync(
            reason: "\(reason)Continuation",
            force: true,
            remainingImmediateFollowUps: remainingImmediateFollowUps - 1
        )
    }
}
