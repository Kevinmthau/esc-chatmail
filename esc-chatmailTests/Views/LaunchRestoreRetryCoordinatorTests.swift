import XCTest
@testable import esc_chatmail

/// A held account's launch restore runs again by itself (`LaunchRestoreRetryCoordinator`):
/// when the network path returns, after a backoff while the path is usable, and when the
/// app comes to the foreground, one attempt at a time and only while an account is held.
@MainActor
final class LaunchRestoreRetryCoordinatorTests: XCTestCase {

    // Revert-check: fails if `scheduleAutomaticRetryIfHeld` stops waiting on
    // `waitUntilPathSatisfied()` (a path that is down would then be retried on the
    // backoff, and never on its return).
    func testStart_pathDown_retriesWhenThePathReturns() async {
        let fixture = Fixture(pathSatisfied: false)
        fixture.coordinator.start(isInBackground: false)
        // Long enough for a wait that did not wait for the path to have tried.
        try? await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertTrue(fixture.coordinator.isRetryScheduled)
        XCTAssertEqual(fixture.restore.calls, 0)
        XCTAssertTrue(fixture.sleeper.requestedDelays.isEmpty, "A path known to be down waits for the path, not a timer")

        fixture.pathMonitor.pathDidChange(isSatisfied: true)
        // Revert-check: fails if the settle wait after the path's return is removed
        // (the attempt would start at once, with no sleep asked for).
        await waitUntil { fixture.sleeper.pendingCount == 1 }
        XCTAssertEqual(fixture.sleeper.requestedDelays, [LaunchRestoreRetryPolicy.pathReturnSettleDelay])
        XCTAssertEqual(fixture.restore.calls, 0)
        fixture.sleeper.fireAll()

        await waitUntil { fixture.restore.calls == 1 }
        await waitUntil { !fixture.coordinator.isRestoring }
    }

    // Revert-check: fails if `attemptDidFinish` stops counting the failure (the second
    // wait would be the first's 15 seconds again) or stops scheduling the next wait.
    func testStart_pathUsable_retriesAfterABackoffThatDoubles() async {
        let fixture = Fixture(pathSatisfied: true)
        fixture.coordinator.start(isInBackground: false)
        await waitUntil { fixture.sleeper.pendingCount == 1 }
        XCTAssertEqual(fixture.sleeper.requestedDelays, [15])

        fixture.sleeper.fireAll()

        await waitUntil { fixture.restore.calls == 1 }
        await waitUntil { fixture.sleeper.pendingCount == 1 }
        XCTAssertEqual(fixture.sleeper.requestedDelays, [15, 30])
    }

    func testRetryNow_whileAnAttemptRuns_startsNoSecond() async {
        let fixture = Fixture(pathSatisfied: false)
        fixture.restore.blocks = true
        fixture.coordinator.start(isInBackground: false)

        fixture.coordinator.retryNow()
        await waitUntil { fixture.restore.calls == 1 }
        XCTAssertTrue(fixture.coordinator.isRestoring)
        fixture.coordinator.retryNow()
        fixture.coordinator.handle(.retry)
        fixture.restore.release()
        await waitUntil { !fixture.coordinator.isRestoring }

        XCTAssertEqual(fixture.restore.calls, 1)
    }

    func testNoHeldAccount_neverAttemptsOrWaits() async {
        let fixture = Fixture(pathSatisfied: true)
        fixture.isHeld.value = false
        fixture.coordinator.start(isInBackground: false)
        fixture.coordinator.retryNow()
        fixture.coordinator.handle(.retry)
        fixture.pathMonitor.pathDidChange(isSatisfied: true)
        try? await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(fixture.restore.calls, 0)
        XCTAssertFalse(fixture.coordinator.isRetryScheduled)
        XCTAssertTrue(fixture.sleeper.requestedDelays.isEmpty)
    }

    // HONEST SCOPE: both `attemptDidFinish` and `scheduleAutomaticRetryIfHeld` refuse
    // without a held account, so this fails only if both checks are removed.
    func testAttemptThatEndsTheHold_schedulesNothingMore() async {
        let fixture = Fixture(pathSatisfied: true)
        fixture.restore.onRun = { fixture.isHeld.value = false }
        fixture.coordinator.start(isInBackground: false)

        fixture.coordinator.retryNow()
        await waitUntil { fixture.restore.calls == 1 && !fixture.coordinator.isRestoring }

        XCTAssertFalse(fixture.coordinator.isRetryScheduled)
    }

    // Revert-check: fails if `.pause` stops cancelling the scheduled retry: a retry
    // waiting on the path would then run while the iOS app is in the background.
    func testPause_cancelsTheWait_andForegroundRetriesAtOnce() async {
        let fixture = Fixture(pathSatisfied: false)
        fixture.coordinator.start(isInBackground: false)

        fixture.coordinator.handle(.pause)
        XCTAssertFalse(fixture.coordinator.isRetryScheduled)
        fixture.pathMonitor.pathDidChange(isSatisfied: true)
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(fixture.restore.calls, 0)

        fixture.coordinator.handle(.retry)
        await waitUntil { fixture.restore.calls == 1 }
    }

    // Revert-check: fails if `handle(.retry)` stops scheduling the wait again when the
    // attempt is refused: after a pause, a foregrounding moments after the last attempt
    // left nothing waiting, and the account stayed held until the next foregrounding.
    func testForegroundRightAfterAnAttempt_isRefusedButWaitsAgain() async {
        let fixture = Fixture(pathSatisfied: false)
        fixture.coordinator.start(isInBackground: false)
        fixture.coordinator.retryNow()
        await waitUntil { fixture.restore.calls == 1 && !fixture.coordinator.isRestoring }
        XCTAssertTrue(fixture.coordinator.isRetryScheduled)

        fixture.coordinator.handle(.pause)
        fixture.clock.value = fixture.clock.value.addingTimeInterval(1)
        fixture.coordinator.handle(.retry)

        XCTAssertEqual(fixture.restore.calls, 1)
        XCTAssertTrue(fixture.coordinator.isRetryScheduled)

        fixture.clock.value = fixture.clock.value.addingTimeInterval(LaunchRestoreRetryPolicy.minimumForegroundInterval)
        fixture.coordinator.handle(.retry)
        await waitUntil { fixture.restore.calls == 2 }
    }

    func testBeforeStart_eventsDoNothing() async {
        let fixture = Fixture(pathSatisfied: true)
        fixture.coordinator.handle(.retry)
        fixture.coordinator.retryNow()
        try? await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(fixture.restore.calls, 0)
        XCTAssertFalse(fixture.coordinator.isRetryScheduled)
    }

    /// An iOS app initialized in the background waits for its first activation.
    func testStartInBackground_waitsForTheFirstForegrounding() async {
        let fixture = Fixture(pathSatisfied: false)
        fixture.coordinator.start(isInBackground: true)
        XCTAssertFalse(fixture.coordinator.isRetryScheduled)

        fixture.coordinator.handle(.retry)

        await waitUntil { fixture.restore.calls == 1 }
    }

    // MARK: - Fixtures

    @MainActor
    private final class Fixture {
        let restore: ControlledRestore
        let isHeld: LaunchRestoreTestBox<Bool>
        let clock: LaunchRestoreTestBox<Date>
        let sleeper: ManualRetrySleeper
        let pathMonitor: OutboundNetworkPathMonitor
        let coordinator: LaunchRestoreRetryCoordinator

        init(pathSatisfied: Bool) {
            let pathMonitor = OutboundNetworkPathMonitor(manualPathSatisfied: pathSatisfied)
            let restore = ControlledRestore()
            let isHeld = LaunchRestoreTestBox(true)
            let clock = LaunchRestoreTestBox(Date(timeIntervalSinceReferenceDate: 1_000_000))
            let sleeper = ManualRetrySleeper()
            self.pathMonitor = pathMonitor
            self.restore = restore
            self.isHeld = isHeld
            self.clock = clock
            self.sleeper = sleeper
            coordinator = LaunchRestoreRetryCoordinator(
                restore: { await restore.run() },
                hasHeldAccount: { isHeld.value },
                pathMonitor: pathMonitor,
                sleep: { await sleeper.sleep($0) },
                now: { clock.value }
            )
        }
    }

    private func waitUntil(
        timeout: TimeInterval = 5,
        pollIntervalNanoseconds: UInt64 = 5_000_000,
        condition: @MainActor () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else {
                XCTFail("Timed out waiting for condition")
                return
            }
            try? await Task.sleep(nanoseconds: pollIntervalNanoseconds)
        }
    }
}

@MainActor
private final class ControlledRestore {
    private(set) var calls = 0
    var blocks = false
    var onRun: (@MainActor () -> Void)?
    private var waiter: CheckedContinuation<Void, Never>?

    func run() async {
        calls += 1
        if blocks {
            await withCheckedContinuation { waiter = $0 }
        }
        onRun?()
    }

    func release() {
        waiter?.resume()
        waiter = nil
    }
}

/// `@unchecked Sendable`: every reader and writer is on the main actor.
private final class LaunchRestoreTestBox<Value>: @unchecked Sendable {
    var value: Value
    init(_ value: Value) { self.value = value }
}

/// A sleep the test ends. `@unchecked Sendable`: `lock` guards both fields.
private final class ManualRetrySleeper: @unchecked Sendable {
    private let lock = NSLock()
    private var waiters: [UUID: CheckedContinuation<Bool, Never>] = [:]
    private var delays: [TimeInterval] = []

    var requestedDelays: [TimeInterval] {
        lock.withLock { delays }
    }

    var pendingCount: Int {
        lock.withLock { waiters.count }
    }

    func sleep(_ delay: TimeInterval) async -> Bool {
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                let cancelled = lock.withLock { () -> Bool in
                    delays.append(delay)
                    if Task.isCancelled { return true }
                    waiters[id] = continuation
                    return false
                }
                if cancelled {
                    continuation.resume(returning: false)
                }
            }
        } onCancel: {
            let waiter = lock.withLock { waiters.removeValue(forKey: id) }
            waiter?.resume(returning: false)
        }
    }

    func fireAll() {
        let fired = lock.withLock { () -> [CheckedContinuation<Bool, Never>] in
            let fired = Array(waiters.values)
            waiters.removeAll()
            return fired
        }
        fired.forEach { $0.resume(returning: true) }
    }
}
