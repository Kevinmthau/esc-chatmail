import Foundation

enum SyncRunKind: String, Sendable, Equatable {
    case foregroundInitial
    case foregroundIncremental
    case background
    case pendingActions
    case maintenance

    var isForeground: Bool {
        switch self {
        case .foregroundInitial, .foregroundIncremental:
            return true
        case .background, .pendingActions, .maintenance:
            return false
        }
    }
}

struct SyncRun: Sendable, Equatable {
    fileprivate let id: UUID
    let kind: SyncRunKind
}

struct SyncRunTask: Sendable {
    let run: SyncRun
    let task: Task<Void, Error>
}

/// Identifies the account epoch in which a piece of account-scoped work was
/// requested. A request remains valid while waiting behind ordinary sync work,
/// but any account transition invalidates it before the persistent store can be
/// replaced.
struct AccountWorkRequest: Sendable, Equatable {
    fileprivate let generation: UInt64
}

actor SyncRunCoordinator {
    static let shared = SyncRunCoordinator()

    private struct ActiveRun {
        let run: SyncRun
        let task: Task<Void, Error>?
    }

    private var activeRun: ActiveRun?
    /// Non-exclusive account-scoped leases. They run concurrently with an
    /// active sync run so an interactive local mutation is never serialized
    /// behind minutes of sync, but they still sit inside the account
    /// transition boundary: they are refused once teardown starts, and
    /// `beginQuiescence()` drains them before destructive cleanup runs.
    private var accountWorkLeases: Set<UUID> = []
    private var accountGeneration: UInt64 = 0
    /// While true, account teardown owns the single-flight boundary. New
    /// sync/pending-action/background runs stay parked until teardown has
    /// finished resetting account-scoped storage.
    private var isQuiescing = false
    private var quiescenceAcquisitionWaiters: [CheckedContinuation<Void, Never>] = []
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []
    private var workWaitingObservers: [CheckedContinuation<Void, Never>] = []
    /// Resumed only once the exclusive run and every non-exclusive lease have
    /// been released, so account teardown waits for both.
    private var boundaryDrainWaiters: [CheckedContinuation<Void, Never>] = []

    func beginRun(kind: SyncRunKind) -> SyncRun? {
        guard activeRun == nil, !isQuiescing else {
            return nil
        }

        let run = SyncRun(id: UUID(), kind: kind)
        activeRun = ActiveRun(run: run, task: nil)
        return run
    }

    func beginRunWithTask(
        kind: SyncRunKind,
        taskBuilder: () -> Task<Void, Error>
    ) -> SyncRunTask? {
        guard activeRun == nil, !isQuiescing else {
            return nil
        }

        let run = SyncRun(id: UUID(), kind: kind)
        let task = taskBuilder()
        activeRun = ActiveRun(run: run, task: task)
        return SyncRunTask(run: run, task: task)
    }

    /// Run-aware task construction lets work validate the exact lease that
    /// owns it while registering cancellation atomically with acquisition.
    func beginRunWithTask(
        kind: SyncRunKind,
        taskBuilder: (SyncRun) -> Task<Void, Error>
    ) -> SyncRunTask? {
        guard activeRun == nil, !isQuiescing else {
            return nil
        }

        let run = SyncRun(id: UUID(), kind: kind)
        let task = taskBuilder(run)
        activeRun = ActiveRun(run: run, task: task)
        return SyncRunTask(run: run, task: task)
    }

    /// Captures the current account epoch for work that may need to wait behind
    /// an active run. Work requested during teardown is rejected immediately.
    func makeAccountWorkRequest() -> AccountWorkRequest? {
        guard !isQuiescing else { return nil }
        return AccountWorkRequest(generation: accountGeneration)
    }

    /// Waits for the single-flight boundary and acquires it only if no account
    /// transition has started since `request` was created. This prevents work
    /// queued for the old account from resuming into a freshly reset store.
    func acquireRun(kind: SyncRunKind, for request: AccountWorkRequest) async -> SyncRun? {
        while true {
            guard !Task.isCancelled,
                  !isQuiescing,
                  request.generation == accountGeneration else {
                return nil
            }

            if activeRun == nil {
                let run = SyncRun(id: UUID(), kind: kind)
                activeRun = ActiveRun(run: run, task: nil)
                return run
            }

            await parkUntilIdle()
        }
    }

    /// Grants a non-exclusive, account-scoped lease. Unlike `acquireRun`, this
    /// never waits for the single-flight boundary, so an optimistic local
    /// mutation and its durable enqueue are not serialized behind an unrelated
    /// sync run. The account-transition contract is unchanged: the lease is
    /// refused during teardown or after any transition since `request` was
    /// made, `isActiveRun(_:)` validates it, and `beginQuiescence()` waits for
    /// it to be released before the persistent store can be replaced.
    ///
    /// Deliberately does NOT check `Task.isCancelled` (unlike `acquireRun`): a
    /// UI action from a cancelled SwiftUI task must still apply its optimistic
    /// mutation, so cancellation is not a silent-drop path here.
    ///
    /// A lease holder must never wait on the exclusive boundary
    /// (`waitUntilIdle`/`beginRun`/`acquireRun`) before releasing its lease:
    /// teardown drains leases, so that would deadlock quiescence.
    func acquireAccountWorkLease(
        kind: SyncRunKind,
        for request: AccountWorkRequest
    ) -> SyncRun? {
        guard !isQuiescing, request.generation == accountGeneration else {
            return nil
        }

        let run = SyncRun(id: UUID(), kind: kind)
        accountWorkLeases.insert(run.id)
        return run
    }

    func endRun(_ run: SyncRun) {
        if accountWorkLeases.remove(run.id) != nil {
            // Releasing a lease does not open the single-flight boundary, so
            // idle waiters must stay parked behind `activeRun`/`isQuiescing`.
            resumeBoundaryDrainWaitersIfDrained()
            return
        }

        guard activeRun?.run.id == run.id else {
            return
        }

        activeRun = nil
        resumeBoundaryDrainWaitersIfDrained()
        resumeIdleWaitersIfAvailable()
    }

    @discardableResult
    func cancelForegroundRun() -> Bool {
        guard let activeRun, activeRun.run.kind.isForeground else {
            return false
        }

        activeRun.task?.cancel()
        return true
    }

    func waitUntilIdle() async {
        guard activeRun != nil || isQuiescing else {
            return
        }

        await parkUntilIdle()
    }

    /// Observable synchronization point for callers/tests that must know work
    /// has actually parked behind the account boundary before transitioning it.
    func waitUntilWorkIsWaiting() async {
        guard idleWaiters.isEmpty else { return }

        await withCheckedContinuation { continuation in
            workWaitingObservers.append(continuation)
        }
    }

    func isRunning() -> Bool {
        activeRun != nil
    }

    func activeRunKind() -> SyncRunKind? {
        activeRun?.run.kind
    }

    func isActiveRun(_ run: SyncRun) -> Bool {
        activeRun?.run.id == run.id || accountWorkLeases.contains(run.id)
    }

    /// Prevents new account-scoped work, cancels a cancellable active run, and
    /// waits for the current owner to release the boundary. Callers must pair
    /// this with `endQuiescence()` after destructive account cleanup.
    func beginQuiescence() async {
        if isQuiescing {
            // Account teardowns are destructive and must not overlap each
            // other. Transfer the lease directly from the current owner when
            // it ends, keeping normal run acquisition blocked between them.
            await withCheckedContinuation { continuation in
                quiescenceAcquisitionWaiters.append(continuation)
            }
        } else {
            isQuiescing = true
            accountGeneration &+= 1
        }

        activeRun?.task?.cancel()

        // Drain the exclusive run and every non-exclusive account-work lease.
        // Leases are short, local, and uncancellable, and no new one can be
        // granted while `isQuiescing` stays true, so `accountWorkLeases` only
        // shrinks from here and this loop terminates.
        while activeRun != nil || !accountWorkLeases.isEmpty {
            await withCheckedContinuation { continuation in
                boundaryDrainWaiters.append(continuation)
            }
        }
    }

    func endQuiescence() {
        guard isQuiescing else { return }
        if !quiescenceAcquisitionWaiters.isEmpty {
            let nextOwner = quiescenceAcquisitionWaiters.removeFirst()
            nextOwner.resume()
            return
        }

        isQuiescing = false
        resumeIdleWaitersIfAvailable()
    }

    private func resumeBoundaryDrainWaitersIfDrained() {
        guard activeRun == nil,
              accountWorkLeases.isEmpty,
              !boundaryDrainWaiters.isEmpty else { return }

        let waiters = boundaryDrainWaiters
        boundaryDrainWaiters.removeAll(keepingCapacity: false)
        waiters.forEach { $0.resume() }
    }

    private func parkUntilIdle() async {
        await withCheckedContinuation { continuation in
            idleWaiters.append(continuation)
            let observers = workWaitingObservers
            workWaitingObservers.removeAll(keepingCapacity: false)
            observers.forEach { $0.resume() }
        }
    }

    private func resumeIdleWaitersIfAvailable() {
        guard activeRun == nil, !isQuiescing else { return }
        guard !idleWaiters.isEmpty else { return }

        let waiters = idleWaiters
        idleWaiters.removeAll(keepingCapacity: false)
        waiters.forEach { $0.resume() }
    }
}
