import XCTest
@testable import esc_chatmail

final class AsyncTimeoutTests: XCTestCase {

    func testWithSoftTimeout_returnsWorkResultWhenWorkFinishesFirst() async {
        let result = await withSoftTimeout(seconds: 1.0) {
            try? await Task.sleep(nanoseconds: 10_000_000) // 10 ms
            return 42
        }

        XCTAssertEqual(result, 42)
    }

    func testWithSoftTimeout_releasesWorkResultBeforeTimeoutTaskWakes() async {
        let box = await droppedSoftTimeoutPayload()

        for _ in 0..<20 where box.value != nil {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }

        XCTAssertNil(box.value, "the timeout gate should not retain the returned work value after resuming")
    }

    func testWithSoftTimeout_returnsNilWhenTimeoutFiresFirst() async {
        let start = Date()
        let result = await withSoftTimeout(seconds: 0.1) {
            // Sleep far longer than the soft timeout to guarantee the timer wins.
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            return "should not surface"
        }
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertNil(result)
        // Caller must unblock within the soft-timeout budget (plus headroom for
        // scheduling jitter in CI). Crucially, must NOT wait for the 5s sleep.
        XCTAssertLessThan(elapsed, 1.5)
    }

    func testWithSoftTimeout_doesNotCancelWorkAfterTimeout() async {
        // The work task must keep running after the timeout — that's the point
        // of a *soft* timeout (cache-warming behavior). We assert this by having
        // the work flip a flag after the caller has already returned nil.
        actor Flag {
            private(set) var didCompleteWork = false
            func mark() { didCompleteWork = true }
        }
        let flag = Flag()

        let result = await withSoftTimeout(seconds: 0.05) {
            try? await Task.sleep(nanoseconds: 200_000_000) // 200 ms — longer than the timeout
            await flag.mark()
            return "done"
        }

        XCTAssertNil(result, "caller should have given up on the timeout")

        // Give the background work time to finish, then assert it ran to completion.
        try? await Task.sleep(nanoseconds: 400_000_000)
        let completed = await flag.didCompleteWork
        XCTAssertTrue(completed, "soft timeout must NOT cancel the underlying work")
    }

    private func droppedSoftTimeoutPayload() async -> WeakBox<TimeoutPayload> {
        let box = WeakBox<TimeoutPayload>()
        var payload: TimeoutPayload? = await withSoftTimeout(seconds: 2.0) {
            TimeoutPayload()
        }
        XCTAssertNotNil(payload)
        box.value = payload
        payload = nil
        return box
    }
}

private final class TimeoutPayload: @unchecked Sendable {}

private final class WeakBox<Object: AnyObject>: @unchecked Sendable {
    weak var value: Object?
}
