import XCTest
@testable import esc_chatmail

@MainActor
final class ViewModelTaskManagerTests: XCTestCase {
    func testRun_oldCompletionDoesNotClearNewerTask() async {
        await assertOldCompletionDoesNotClearNewerTask(mode: .inherited) { manager, key in
            manager.cancel(key)
        }
    }

    func testRunDetached_oldCompletionDoesNotClearNewerTask() async {
        await assertOldCompletionDoesNotClearNewerTask(mode: .detached) { manager, key in
            manager.cancel(key)
        }
    }

    func testCancelAll_afterOldCompletionStillCancelsCurrentTask() async {
        await assertOldCompletionDoesNotClearNewerTask(mode: .inherited) { manager, _ in
            manager.cancelAll()
        }
    }

    private func assertOldCompletionDoesNotClearNewerTask(
        mode: RunMode,
        cancelCurrentTask: (ViewModelTaskManager, String) -> Void,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let manager = ViewModelTaskManager()
        let recorder = TaskEventRecorder()
        let firstGate = AsyncGate()
        let secondGate = AsyncGate()
        let key = "replacement"

        startTask(manager, key: key, mode: mode) {
            await recorder.record(.firstStarted)
            await firstGate.wait()
            await recorder.record(.firstFinished)
        }

        await waitUntil(
            { await recorder.contains(.firstStarted) },
            "first task should start",
            file: file,
            line: line
        )

        startTask(manager, key: key, mode: mode) {
            await withTaskCancellationHandler {
                await recorder.record(.secondWaiting)
                await secondGate.wait()
            } onCancel: {
                Task {
                    await recorder.record(.secondCancelled)
                }
            }
        }

        await waitUntil(
            { await recorder.contains(.secondWaiting) },
            "replacement task should start",
            file: file,
            line: line
        )

        await firstGate.open()
        await waitUntil(
            { await recorder.contains(.firstFinished) },
            "stale task should finish",
            file: file,
            line: line
        )
        await drainMainActor()

        cancelCurrentTask(manager, key)

        await waitUntil(
            { await recorder.contains(.secondCancelled) },
            "current task should still be cancellable after stale completion",
            file: file,
            line: line
        )
        await secondGate.open()
    }

    private func startTask(
        _ manager: ViewModelTaskManager,
        key: String,
        mode: RunMode,
        operation: @escaping @Sendable () async -> Void
    ) {
        switch mode {
        case .inherited:
            manager.run(key, operation: operation)
        case .detached:
            manager.runDetached(key, operation: operation)
        }
    }

    private func waitUntil(
        _ predicate: @escaping () async -> Bool,
        _ message: String,
        timeout: TimeInterval = 1.0,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await predicate() {
                return
            }

            try? await Task.sleep(nanoseconds: 10_000_000)
        }

        XCTFail(message, file: file, line: line)
    }

    private func drainMainActor() async {
        for _ in 0..<5 {
            await Task.yield()
        }
    }

    private enum RunMode {
        case inherited
        case detached
    }
}

private actor AsyncGate {
    private var isOpen = false
    private var continuations: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else {
            return
        }

        await withCheckedContinuation { continuation in
            continuations.append(continuation)
        }
    }

    func open() {
        guard !isOpen else {
            return
        }

        isOpen = true
        let pendingContinuations = continuations
        self.continuations.removeAll()
        pendingContinuations.forEach { $0.resume() }
    }
}

private actor TaskEventRecorder {
    private var events: [TaskEvent] = []

    func record(_ event: TaskEvent) {
        events.append(event)
    }

    func contains(_ event: TaskEvent) -> Bool {
        events.contains(event)
    }
}

private enum TaskEvent: Equatable, Sendable {
    case firstStarted
    case firstFinished
    case secondWaiting
    case secondCancelled
}
