import XCTest
@testable import esc_chatmail

/// Pins the counter the Mac's quit waits on for reply-draft writes
/// (`AppTerminationWait`): idle only once every counted write has ended, each
/// write counted once however often it is ended, and a wait that a cancelled
/// caller leaves at once without ending anything.
@MainActor
final class ReplyDraftWriteTrackerTests: XCTestCase {

    func testWaitUntilIdle_noWrites_returnsWithoutWaiting() async {
        let tracker = ReplyDraftWriteTracker()

        await tracker.waitUntilIdle()

        XCTAssertFalse(tracker.hasOutstandingWrites)
        XCTAssertEqual(tracker.idleWaiterCount, 0)
    }

    // Revert-check: fails (the second `end()` of the first write ends the
    // other one too) if `ReplyDraftWriteTracker.Write.end` loses its
    // `hasEnded` guard.
    func testWriteEnd_calledTwice_endsOnlyThatWrite() {
        let tracker = ReplyDraftWriteTracker()
        let first = tracker.beginWrite()
        let second = tracker.beginWrite()

        first.end()
        first.end()

        XCTAssertTrue(tracker.hasOutstandingWrites, "The second write has not ended")
        second.end()
        XCTAssertFalse(tracker.hasOutstandingWrites)
    }

    // Revert-check: fails (the waiter is released, synchronously, while a
    // write is outstanding) if `ReplyDraftWriteTracker.endWrite` resumes its
    // waiters on any end instead of the last one's.
    func testWaitUntilIdle_twoWrites_returnsOnlyWhenTheLastOneEnds() async {
        let tracker = ReplyDraftWriteTracker()
        let first = tracker.beginWrite()
        let second = tracker.beginWrite()
        let returned = expectation(description: "wait returned")

        Task { @MainActor in
            await tracker.waitUntilIdle()
            returned.fulfill()
        }
        await waitUntil { tracker.idleWaiterCount == 1 }
        first.end()
        // `endWrite` releases waiters in the call itself, so a release would
        // already show here.
        XCTAssertEqual(tracker.idleWaiterCount, 1)
        XCTAssertTrue(tracker.hasOutstandingWrites)

        second.end()
        await fulfillment(of: [returned], timeout: 2)
        XCTAssertEqual(tracker.idleWaiterCount, 0)
    }

    // Revert-check: fails (the task never returns) if
    // `ReplyDraftWriteTracker.waitUntilIdle()` loses its cancellation
    // handler, which is what lets the quit's deadline end the wait.
    func testWaitUntilIdle_cancelled_returnsAndLeavesTheWriteCounted() async {
        let tracker = ReplyDraftWriteTracker()
        let write = tracker.beginWrite()
        let returned = expectation(description: "wait returned")

        let waitTask = Task { @MainActor in
            await tracker.waitUntilIdle()
            returned.fulfill()
        }
        await waitUntil { tracker.idleWaiterCount == 1 }
        waitTask.cancel()
        await fulfillment(of: [returned], timeout: 2)

        XCTAssertEqual(tracker.idleWaiterCount, 0)
        XCTAssertTrue(tracker.hasOutstandingWrites)
        write.end()
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
