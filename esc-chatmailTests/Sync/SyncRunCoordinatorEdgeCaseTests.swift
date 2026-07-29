import XCTest
@testable import esc_chatmail

/// Edge-case characterization for `SyncRunCoordinator`'s single-flight
/// contract, complementing `SyncRunCoordinatorTests`: rejected task builders
/// never run, stale end tokens are no-ops, all idle waiters resume together,
/// and idle-state queries behave when nothing is running.
final class SyncRunCoordinatorEdgeCaseTests: XCTestCase {

    func testBeginRunWithTaskRejectionDoesNotInvokeTaskBuilder() async {
        let coordinator = SyncRunCoordinator()
        let first = await coordinator.beginRun(kind: .background)
        XCTAssertNotNil(first)

        let builderRan = LockedFlag()
        let rejected = await coordinator.beginRunWithTask(kind: .foregroundIncremental) {
            builderRan.set()
            return Task { }
        }

        XCTAssertNil(rejected)
        XCTAssertFalse(builderRan.isSet, "A rejected request must not spawn an orphan Task")

        if let first { await coordinator.endRun(first) }
    }

    func testStaleEndRunTokenDoesNotEndTheNextRun() async {
        let coordinator = SyncRunCoordinator()
        let first = await coordinator.beginRun(kind: .foregroundIncremental)!
        await coordinator.endRun(first)

        let second = await coordinator.beginRun(kind: .background)
        XCTAssertNotNil(second)

        // Replaying the first run's token must not clear the second run.
        await coordinator.endRun(first)
        let running = await coordinator.isRunning()
        let kind = await coordinator.activeRunKind()
        XCTAssertTrue(running)
        XCTAssertEqual(kind, .background)

        if let second { await coordinator.endRun(second) }
    }

    func testAllIdleWaitersResumeOnEndRun() async {
        let coordinator = SyncRunCoordinator()
        let run = await coordinator.beginRun(kind: .foregroundIncremental)!

        let waiters = (0..<3).map { _ in
            Task { await coordinator.waitUntilIdle() }
        }
        // Let the waiters park before the run ends.
        await Task.yield()
        await Task.yield()

        await coordinator.endRun(run)

        for waiter in waiters {
            await waiter.value
        }
        let running = await coordinator.isRunning()
        XCTAssertFalse(running)
    }

    func testWaitUntilIdleReturnsImmediatelyWhenIdle() async {
        let coordinator = SyncRunCoordinator()
        await coordinator.waitUntilIdle()
        let running = await coordinator.isRunning()
        XCTAssertFalse(running)
    }

    func testCancelForegroundRunReturnsFalseWhenIdle() async {
        let coordinator = SyncRunCoordinator()
        let cancelled = await coordinator.cancelForegroundRun()
        XCTAssertFalse(cancelled)
    }
}

private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var _isSet = false

    var isSet: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _isSet
    }

    func set() {
        lock.lock()
        _isSet = true
        lock.unlock()
    }
}
