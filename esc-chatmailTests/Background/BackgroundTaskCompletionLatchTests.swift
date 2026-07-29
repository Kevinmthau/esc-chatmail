import XCTest
@testable import esc_chatmail

/// Exactly-once semantics for the background-task completion latch: the first
/// `complete` wins (normal completion vs expiration vs deallocation), later
/// calls are ignored, and concurrent racers produce exactly one callback.
final class BackgroundTaskCompletionLatchTests: XCTestCase {

    func testFirstCompletionWinsAndLaterCallsAreIgnored() {
        var outcomes: [Bool] = []
        let latch = BackgroundTaskCompletionLatch { outcomes.append($0) }

        latch.complete(success: true)
        latch.complete(success: false)
        latch.complete(success: true)

        XCTAssertEqual(outcomes, [true])
    }

    func testExpirationBeforeNormalCompletionReportsFailureOnce() {
        var outcomes: [Bool] = []
        let latch = BackgroundTaskCompletionLatch { outcomes.append($0) }

        // Expiration fires first (cancel + fail), then the sync task finishes.
        latch.complete(success: false)
        latch.complete(success: true)

        XCTAssertEqual(outcomes, [false])
    }

    func testConcurrentCompletionsInvokeCallbackExactlyOnce() async {
        let calls = NSLockedCounter()
        let latch = BackgroundTaskCompletionLatch { _ in calls.increment() }

        await withTaskGroup(of: Void.self) { group in
            for index in 0..<100 {
                group.addTask {
                    latch.complete(success: index.isMultiple(of: 2))
                }
            }
        }

        XCTAssertEqual(calls.value, 1)
    }
}

private final class NSLockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = 0

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return _value
    }

    func increment() {
        lock.lock()
        _value += 1
        lock.unlock()
    }
}
