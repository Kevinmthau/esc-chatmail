import Foundation

@MainActor
protocol ForegroundSyncPerforming: AnyObject {
    /// - Parameter completion: called once a started run has succeeded, with
    ///   whether the run left work for a follow-up. It answers whether the
    ///   caller queued that follow-up to run at once. The engine then leaves
    ///   the run boundary to it and asks for nothing of its own after this
    ///   run (`SyncEngine.runStoreMaintenanceAfterSync()`).
    func triggerIncrementalSyncIfPossible(
        completion: @escaping @MainActor @Sendable (Bool) -> Bool
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
    /// The path whose return asks for a sync: the one `SyncEngine.shared`
    /// asks before each run (`NetworkMonitorService.shared`).
    private let networkPath: any SyncNetworkPathMonitoring
    private let periodicInterval: TimeInterval
    private let minimumSyncGap: TimeInterval
    private let maxImmediateFollowUpRuns: Int
    private let log = LogCategory.sync.logger

    private var periodicTask: Task<Void, Never>?
    /// Hears the path come back, from `start` to `stop`
    /// (`startUsablePathObservation()`).
    private var usablePathTask: Task<Void, Never>?
    private var deferredSyncTask: Task<Void, Never>?
    private var deferredSyncTaskID: UUID?
    private var lastSyncTriggerAt: Date?

    init(
        syncEngine: (any ForegroundSyncPerforming)? = nil,
        authSession: (any ForegroundSyncAuthenticationProviding)? = nil,
        networkPath: (any SyncNetworkPathMonitoring)? = nil,
        periodicInterval: TimeInterval = 60,
        minimumSyncGap: TimeInterval = 30,
        maxImmediateFollowUpRuns: Int = 3
    ) {
        self.syncEngine = syncEngine ?? SyncEngine.shared
        self.authSession = authSession ?? AuthSession.shared
        self.networkPath = networkPath ?? NetworkMonitorService.shared
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
        startUsablePathObservation()

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
        usablePathTask?.cancel()
        usablePathTask = nil
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

    /// Asks for a sync when the path comes back after it was known to be
    /// down (`SyncNetworkPathMonitoring.usablePathReturns()`). A run skipped
    /// for no network used to wait for the next 60-second tick or the next
    /// activation, while pending actions resumed at once (architecture review
    /// 2026-11, background-energy#5).
    ///
    /// Subscribed in `start` and cancelled in `stop`, so the iOS app in the
    /// background, a Mac asleep or a signed-out session starts nothing. The
    /// request is an ordinary `triggerSync(force: false)` on the main actor,
    /// never a call into the engine from the monitor's queue: the mailbox
    /// gate applies, and so does the minimum gap, so a link that flaps does
    /// not sync at every return.
    private func startUsablePathObservation() {
        guard usablePathTask == nil else { return }
        let returns = networkPath.usablePathReturns()
        usablePathTask = Task { [weak self] in
            for await _ in returns {
                guard let self else { return }
                guard !Task.isCancelled, self.periodicTask != nil else { continue }
                self.triggerSync(reason: "networkPathBecameUsable", force: false)
            }
        }
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
                guard needsFollowUp, let self else { return false }
                return self.scheduleImmediateFollowUp(
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
        case .skippedInsufficientStorage:
            // The engine owns the storage backoff, so the periodic loop can keep its cadence:
            // a refused run fetches nothing, and the engine admits one once space is freed.
            log.debug("Skipping foreground sync (\(reason)): not enough storage")
            return .skipped
        }
    }

    /// - Returns: whether a continuation was queued. False where the rest
    ///   is left to the periodic loop, and the engine reads that as the end
    ///   of this chain of runs: a run that still needs a follow-up but gets
    ///   none at once (a cursor held by a message that keeps failing asks
    ///   for one after every run) must not keep the store maintenance
    ///   waiting for a continuation that is not coming.
    private func scheduleImmediateFollowUp(
        after reason: String,
        remainingImmediateFollowUps: Int
    ) -> Bool {
        guard authSession.canAccessMailbox, periodicTask != nil else {
            log.debug("Not scheduling foreground sync continuation outside an active session")
            return false
        }
        guard remainingImmediateFollowUps > 0 else {
            log.warning("Foreground sync reached its immediate continuation limit; leaving durable progress for the periodic loop")
            return false
        }

        triggerSync(
            reason: "\(reason)Continuation",
            force: true,
            remainingImmediateFollowUps: remainingImmediateFollowUps - 1
        )
        return true
    }
}
