import XCTest
@testable import esc_chatmail

/// Pins the bounded wait the Mac's quit (`MacAppDelegate.applicationShouldTerminate`)
/// does for sends in flight: it returns when they finish or at the deadline,
/// and in neither case touches a send.
@MainActor
final class OutboundSendTerminationWaitTests: XCTestCase {

    func testWaitForOutstandingSends_noOutstandingSends_finishesWithoutStartingTheDeadline() async {
        let registry = OutboundTaskRegistry(admissionOpen: true)
        let clock = FakeSyncClock()

        let outcome = await OutboundSendTerminationWait.waitForOutstandingSends(
            in: registry,
            timeout: 10,
            clock: clock
        )

        XCTAssertEqual(outcome, .sendsFinished)
        XCTAssertTrue(clock.sleeps.isEmpty)
    }

    // Revert-check: fails (the wait never returns) if
    // `OutboundSendTerminationWait.waitForOutstandingSends` drops its deadline
    // child and waits on the registry alone, and fails the `isActive` check if
    // it cancels the send instead of only waiting for it.
    func testWaitForOutstandingSends_sendStillOutstandingAtDeadline_timesOutAndLeavesTheSendAlone() async throws {
        let registry = OutboundTaskRegistry(admissionOpen: true)
        let reservation = try XCTUnwrap(registry.reserve())
        let clock = FakeSyncClock()
        let returned = expectation(description: "wait returned")
        let recorder = OutcomeRecorder()

        Task { @MainActor in
            recorder.outcome = await OutboundSendTerminationWait.waitForOutstandingSends(
                in: registry,
                timeout: 10,
                clock: clock
            )
            returned.fulfill()
        }
        await fulfillment(of: [returned], timeout: 2)

        XCTAssertEqual(recorder.outcome, .timedOut)
        XCTAssertEqual(clock.sleeps, [10_000_000_000])
        XCTAssertTrue(registry.isActive(reservation), "Quitting must not cancel a send it waits for")
        XCTAssertTrue(registry.hasOutstandingSends)
        XCTAssertEqual(registry.outstandingSendWaiterCount, 0, "The losing waiter must not linger")
        registry.finish(reservation)
    }

    // Revert-check: fails (the wait never returns) if
    // `OutboundTaskRegistry.resumeDrainWaitersIfNeeded` stops resuming the
    // `waitUntilOutstandingSendsFinish()` waiters when the last send finishes.
    func testWaitForOutstandingSends_sendFinishesBeforeDeadline_returnsSendsFinished() async throws {
        let registry = OutboundTaskRegistry(admissionOpen: true)
        let reservation = try XCTUnwrap(registry.reserve())
        let returned = expectation(description: "wait returned")
        let recorder = OutcomeRecorder()

        Task { @MainActor in
            recorder.outcome = await OutboundSendTerminationWait.waitForOutstandingSends(
                in: registry,
                timeout: 10,
                clock: NeverFiringSyncClock()
            )
            returned.fulfill()
        }
        await waitUntil { registry.outstandingSendWaiterCount == 1 }
        registry.finish(reservation)
        await fulfillment(of: [returned], timeout: 2)

        XCTAssertEqual(recorder.outcome, .sendsFinished)
        XCTAssertFalse(registry.hasOutstandingSends)
    }

    // Revert-check: fails (the task never returns) if
    // `OutboundTaskRegistry.waitUntilOutstandingSendsFinish()` loses its
    // cancellation handler, which is what lets the deadline end the wait.
    func testWaitUntilOutstandingSendsFinish_cancelled_returnsAndLeavesTheSendAlone() async throws {
        let registry = OutboundTaskRegistry(admissionOpen: true)
        let reservation = try XCTUnwrap(registry.reserve())
        let returned = expectation(description: "wait returned")

        let waitTask = Task { @MainActor in
            await registry.waitUntilOutstandingSendsFinish()
            returned.fulfill()
        }
        await waitUntil { registry.outstandingSendWaiterCount == 1 }
        waitTask.cancel()
        await fulfillment(of: [returned], timeout: 2)

        XCTAssertEqual(registry.outstandingSendWaiterCount, 0)
        XCTAssertTrue(registry.isActive(reservation))
        registry.finish(reservation)
    }

    /// Polls `condition` until it holds or `timeout` elapses.
    private func waitUntil(
        timeout: TimeInterval = 2.0,
        pollIntervalNanoseconds: UInt64 = 10_000_000,
        file: StaticString = #filePath,
        line: UInt = #line,
        condition: @escaping () async -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while await !condition() {
            guard Date() < deadline else {
                XCTFail("Timed out waiting for condition", file: file, line: line)
                return
            }
            try? await Task.sleep(nanoseconds: pollIntervalNanoseconds)
        }
    }
}

@MainActor
private final class OutcomeRecorder {
    var outcome: OutboundSendTerminationWait.Outcome?
}

/// A deadline that never passes: `sleep` suspends until its task is
/// cancelled, then throws like `Task.sleep`.
private final class NeverFiringSyncClock: SyncClock, @unchecked Sendable {
    func now() -> Date {
        Date(timeIntervalSince1970: 1_700_000_000)
    }

    func sleep(nanoseconds: UInt64) async throws {
        let gate = SingleFireContinuationGate<Bool>()
        _ = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if let settled = gate.install(continuation) {
                    continuation.resume(returning: settled)
                }
            }
        } onCancel: {
            gate.resume(returning: true)
        }
        throw CancellationError()
    }
}
