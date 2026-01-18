import XCTest
@testable import esc_chatmail

final class PeriodicCleanupTaskTests: XCTestCase {

    // MARK: - Test Helper

    actor MockCleanupHandler: PeriodicCleanupHandler {
        var cleanupCount = 0

        func performCleanup() async {
            cleanupCount += 1
        }

        func getCleanupCount() -> Int {
            cleanupCount
        }
    }

    // MARK: - Tests

    func testRunsImmediatelyWhenRequested() async throws {
        let handler = MockCleanupHandler()
        let task = PeriodicCleanupTask()

        // Start with runImmediately = true
        await task.start(handler: handler, interval: .hours(1), runImmediately: true)

        // Give a tiny bit of time for the immediate cleanup to run
        try await Task.sleep(nanoseconds: 100_000_000) // 0.1 seconds

        let count = await handler.getCleanupCount()
        XCTAssertEqual(count, 1, "Should have run cleanup immediately")

        task.cancel()
    }

    func testDoesNotRunImmediatelyWhenNotRequested() async throws {
        let handler = MockCleanupHandler()
        let task = PeriodicCleanupTask()

        // Start with runImmediately = false
        await task.start(handler: handler, interval: .hours(1), runImmediately: false)

        // Give a tiny bit of time
        try await Task.sleep(nanoseconds: 100_000_000) // 0.1 seconds

        let count = await handler.getCleanupCount()
        XCTAssertEqual(count, 0, "Should not have run cleanup immediately")

        task.cancel()
    }

    func testCancelStopsExecution() async throws {
        let handler = MockCleanupHandler()
        let task = PeriodicCleanupTask()

        await task.start(handler: handler, interval: .minutes(1), runImmediately: false)

        // Cancel immediately
        task.cancel()

        // Give some time
        try await Task.sleep(nanoseconds: 100_000_000) // 0.1 seconds

        let count = await handler.getCleanupCount()
        XCTAssertEqual(count, 0, "Should not have run any cleanups after cancel")
    }

    // MARK: - Interval Tests

    func testIntervalMinutesConversion() {
        let interval = PeriodicCleanupTask.Interval.minutes(5)
        XCTAssertEqual(interval.nanoseconds, 5 * 60 * 1_000_000_000)
    }

    func testIntervalHoursConversion() {
        let interval = PeriodicCleanupTask.Interval.hours(2)
        XCTAssertEqual(interval.nanoseconds, 2 * 60 * 60 * 1_000_000_000)
    }
}
