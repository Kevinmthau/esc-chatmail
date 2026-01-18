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
}
