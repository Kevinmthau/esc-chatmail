import Foundation

enum SyncRunKind: String, Sendable, Equatable {
    case foregroundInitial
    case foregroundIncremental
    case background
    case pendingActions

    var isForeground: Bool {
        switch self {
        case .foregroundInitial, .foregroundIncremental:
            return true
        case .background, .pendingActions:
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

actor SyncRunCoordinator {
    static let shared = SyncRunCoordinator()

    private struct ActiveRun {
        let run: SyncRun
        let task: Task<Void, Error>?
    }

    private var activeRun: ActiveRun?
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []

    func beginRun(kind: SyncRunKind) -> SyncRun? {
        guard activeRun == nil else {
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
        guard activeRun == nil else {
            return nil
        }

        let run = SyncRun(id: UUID(), kind: kind)
        let task = taskBuilder()
        activeRun = ActiveRun(run: run, task: task)
        return SyncRunTask(run: run, task: task)
    }

    func endRun(_ run: SyncRun) {
        guard activeRun?.run.id == run.id else {
            return
        }

        activeRun = nil
        resumeIdleWaiters()
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
        guard activeRun != nil else {
            return
        }

        await withCheckedContinuation { continuation in
            idleWaiters.append(continuation)
        }
    }

    func isRunning() -> Bool {
        activeRun != nil
    }

    func activeRunKind() -> SyncRunKind? {
        activeRun?.run.kind
    }

    private func resumeIdleWaiters() {
        guard !idleWaiters.isEmpty else { return }

        let waiters = idleWaiters
        idleWaiters.removeAll(keepingCapacity: false)
        waiters.forEach { $0.resume() }
    }
}
