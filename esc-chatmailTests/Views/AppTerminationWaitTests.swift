import XCTest
@testable import esc_chatmail

/// Pins the bounded wait the Mac's quit (`MacAppDelegate.applicationShouldTerminate`)
/// does for sends in flight and reply-draft writes: it returns when both are
/// idle or at the deadline, and in neither case touches a send.
@MainActor
final class AppTerminationWaitTests: XCTestCase {

    func testWaitForOutstandingWork_nothingOutstanding_finishesWithoutStartingTheDeadline() async {
        let registry = OutboundTaskRegistry(admissionOpen: true)
        let clock = FakeSyncClock()

        let outcome = await AppTerminationWait.waitForOutstandingWork(
            sends: registry,
            draftWrites: ReplyDraftWriteTracker(),
            timeout: 10,
            clock: clock
        )

        XCTAssertEqual(outcome, .finished)
        XCTAssertTrue(clock.sleeps.isEmpty)
    }

    // Revert-check: fails (the wait never returns) if
    // `AppTerminationWait.waitForOutstandingWork` drops its deadline child and
    // waits on the registry alone, and fails the `isActive` check if it
    // cancels the send instead of only waiting for it.
    func testWaitForOutstandingWork_sendStillOutstandingAtDeadline_timesOutAndLeavesTheSendAlone() async throws {
        let registry = OutboundTaskRegistry(admissionOpen: true)
        let reservation = try XCTUnwrap(registry.reserve())
        let clock = FakeSyncClock()
        let returned = expectation(description: "wait returned")
        let recorder = OutcomeRecorder()

        Task { @MainActor in
            recorder.outcome = await AppTerminationWait.waitForOutstandingWork(
                sends: registry,
                draftWrites: ReplyDraftWriteTracker(),
                timeout: 10,
                clock: clock
            )
            returned.fulfill()
        }
        await fulfillment(of: [returned], timeout: 2)

        XCTAssertEqual(recorder.outcome, .timedOut(sendsOutstanding: true, draftWritesOutstanding: false))
        XCTAssertEqual(clock.sleeps, [10_000_000_000])
        XCTAssertTrue(registry.isActive(reservation), "Quitting must not cancel a send it waits for")
        XCTAssertTrue(registry.hasOutstandingSends)
        XCTAssertEqual(registry.outstandingSendWaiterCount, 0, "The losing waiter must not linger")
        registry.finish(reservation)
    }

    // Revert-check: fails (the wait never returns) if
    // `OutboundTaskRegistry.resumeDrainWaitersIfNeeded` stops resuming the
    // `waitUntilOutstandingSendsFinish()` waiters when the last send finishes.
    func testWaitForOutstandingWork_sendFinishesBeforeDeadline_finishes() async throws {
        let registry = OutboundTaskRegistry(admissionOpen: true)
        let reservation = try XCTUnwrap(registry.reserve())
        let returned = expectation(description: "wait returned")
        let recorder = OutcomeRecorder()

        Task { @MainActor in
            recorder.outcome = await AppTerminationWait.waitForOutstandingWork(
                sends: registry,
                draftWrites: ReplyDraftWriteTracker(),
                timeout: 10,
                clock: NeverFiringSyncClock()
            )
            returned.fulfill()
        }
        await waitUntil { registry.outstandingSendWaiterCount == 1 }
        registry.finish(reservation)
        await fulfillment(of: [returned], timeout: 2)

        XCTAssertEqual(recorder.outcome, .finished)
        XCTAssertFalse(registry.hasOutstandingSends)
    }

    // Revert-check: fails (the outcome is `.finished` at once, with no
    // deadline started) if `AppTerminationWait.waitForOutstandingWork` stops
    // asking the draft-write tracker, and the wait never returns if it waits
    // on the tracker with no deadline.
    func testWaitForOutstandingWork_draftWriteStillOutstandingAtDeadline_timesOut() async {
        let registry = OutboundTaskRegistry(admissionOpen: true)
        let tracker = ReplyDraftWriteTracker()
        let write = tracker.beginWrite()
        let clock = FakeSyncClock()
        let returned = expectation(description: "wait returned")
        let recorder = OutcomeRecorder()

        Task { @MainActor in
            recorder.outcome = await AppTerminationWait.waitForOutstandingWork(
                sends: registry,
                draftWrites: tracker,
                timeout: 10,
                clock: clock
            )
            returned.fulfill()
        }
        await fulfillment(of: [returned], timeout: 2)

        XCTAssertEqual(recorder.outcome, .timedOut(sendsOutstanding: false, draftWritesOutstanding: true))
        XCTAssertEqual(clock.sleeps, [10_000_000_000])
        XCTAssertEqual(tracker.idleWaiterCount, 0, "The losing waiter must not linger")
        XCTAssertTrue(tracker.hasOutstandingWrites)
        write.end()
    }

    // Revert-check: fails (the wait never returns) if
    // `ReplyDraftWriteTracker.endWrite` stops resuming the `waitUntilIdle()`
    // waiters when the last write ends.
    func testWaitForOutstandingWork_draftWriteEndsBeforeDeadline_finishes() async {
        let registry = OutboundTaskRegistry(admissionOpen: true)
        let tracker = ReplyDraftWriteTracker()
        let write = tracker.beginWrite()
        let returned = expectation(description: "wait returned")
        let recorder = OutcomeRecorder()

        Task { @MainActor in
            recorder.outcome = await AppTerminationWait.waitForOutstandingWork(
                sends: registry,
                draftWrites: tracker,
                timeout: 10,
                clock: NeverFiringSyncClock()
            )
            returned.fulfill()
        }
        await waitUntil { tracker.idleWaiterCount == 1 }
        write.end()
        await fulfillment(of: [returned], timeout: 2)

        XCTAssertEqual(recorder.outcome, .finished)
    }

    /// A send's release schedules a draft save while the send is still
    /// outstanding (`ChatViewModel.sendReply`'s deferred save): the quit
    /// must wait for that save too, though no draft write was outstanding
    /// when it started waiting.
    // Revert-check: fails (the wait returns `.finished` as the send ends, and
    // the tracker never has a waiter) if `AppTerminationWait.waitForOutstandingWork`
    // waits for the drafts first and then for the sends, with no second look
    // at the drafts.
    func testWaitForOutstandingWork_sendEndsAfterStartingADraftWrite_waitsForTheDraftWriteToo() async throws {
        let registry = OutboundTaskRegistry(admissionOpen: true)
        let reservation = try XCTUnwrap(registry.reserve())
        let tracker = ReplyDraftWriteTracker()
        let returned = expectation(description: "wait returned")
        let recorder = OutcomeRecorder()

        Task { @MainActor in
            recorder.outcome = await AppTerminationWait.waitForOutstandingWork(
                sends: registry,
                draftWrites: tracker,
                timeout: 10,
                clock: NeverFiringSyncClock()
            )
            returned.fulfill()
        }
        await waitUntil { registry.outstandingSendWaiterCount == 1 }
        let write = tracker.beginWrite()
        registry.finish(reservation)
        await waitUntil { tracker.idleWaiterCount == 1 }
        XCTAssertNil(recorder.outcome, "The quit replied with a draft write still outstanding")

        write.end()
        await fulfillment(of: [returned], timeout: 2)

        XCTAssertEqual(recorder.outcome, .finished)
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
    var outcome: AppTerminationWait.Outcome?
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
