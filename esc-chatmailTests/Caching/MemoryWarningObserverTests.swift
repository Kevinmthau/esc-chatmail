import UIKit
import XCTest
@testable import esc_chatmail

final class MemoryWarningObserverTests: XCTestCase {

    // MARK: - Test Helper

    actor MockMemoryWarningHandler: MemoryWarningHandler {
        var warningCount = 0

        func handleMemoryWarning() async {
            warningCount += 1
        }

        func getWarningCount() -> Int {
            warningCount
        }
    }

    // MARK: - Tests

    @MainActor
    func testStopCleansUpObserver() async {
        let handler = MockMemoryWarningHandler()
        let observer = MemoryWarningObserver()

        observer.start(handler: handler)

        // Stop should clean up without errors
        observer.stop()

        // Stop again should be safe (no-op)
        observer.stop()
    }

    @MainActor
    func testStartCanBeCalledMultipleTimes() async {
        let handler = MockMemoryWarningHandler()
        let observer = MemoryWarningObserver()

        // Start multiple times should be safe
        observer.start(handler: handler)
        observer.start(handler: handler)

        observer.stop()
    }

    // The tests below post to a private center: a memory warning posted to
    // the default center would reach every shared cache in the test host.

    @MainActor
    func testStart_memoryWarning_reachesHandler() async {
        let center = NotificationCenter()
        let handler = MockMemoryWarningHandler()
        let observer = MemoryWarningObserver(
            eventSource: MemoryPressureEventSource(notificationCenter: center)
        )
        observer.start(handler: handler)

        center.post(name: UIApplication.didReceiveMemoryWarningNotification, object: nil)

        await waitUntil { await handler.getWarningCount() == 1 }
        observer.stop()
    }

    // Revert-check: fails if `MemoryPressureEventSource.start(onPressure:)`
    // stops calling `stop()` first. A second start then added a second
    // observation and leaked the first, so each warning ran the handler twice.
    @MainActor
    func testEventSourceStart_calledTwice_deliversEachWarningOnce() {
        let center = NotificationCenter()
        let source = MemoryPressureEventSource(notificationCenter: center)
        var deliveries = 0

        source.start { deliveries += 1 }
        source.start { deliveries += 1 }
        center.post(name: UIApplication.didReceiveMemoryWarningNotification, object: nil)

        XCTAssertEqual(deliveries, 1)
        source.stop()
    }

    @MainActor
    func testEventSourceStop_afterStart_deliversNothing() {
        let center = NotificationCenter()
        let source = MemoryPressureEventSource(notificationCenter: center)
        var deliveries = 0

        source.start { deliveries += 1 }
        source.stop()
        center.post(name: UIApplication.didReceiveMemoryWarningNotification, object: nil)

        XCTAssertEqual(deliveries, 0)
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
