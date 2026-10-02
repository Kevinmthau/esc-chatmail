import XCTest
@testable import esc_chatmail

/// `OutboundConnectivityGate` against the production `OutboundNetworkPathMonitor`
/// in manual mode (no system `NWPathMonitor`), with injected clocks: no test
/// here waits on the real network or on wall-clock deadlines.
final class OutboundConnectivityGateTests: XCTestCase {
    func testWaitForUsablePath_unreportedPath_proceedsWithoutStartingDeadline() async throws {
        let monitor = OutboundNetworkPathMonitor(manualPathSatisfied: nil)
        let clock = FakeSyncClock()

        // An unreported path is not "known unsatisfied": the fail-fast send
        // session still turns a genuinely offline attempt into -1009.
        try await OutboundConnectivityGate.waitForUsablePath(monitor: monitor, clock: clock)

        XCTAssertTrue(clock.sleeps.isEmpty)
    }

    func testWaitForUsablePath_pathStaysDown_throwsPreTransmissionNotConnectedAtDeadline() async {
        let monitor = OutboundNetworkPathMonitor(manualPathSatisfied: false)
        let clock = FakeSyncClock()

        do {
            try await OutboundConnectivityGate.waitForUsablePath(
                monitor: monitor,
                clock: clock,
                timeout: 30
            )
            XCTFail("Expected the deadline to fail the send")
        } catch let error as URLError {
            XCTAssertEqual(error.code, .notConnectedToInternet)
            // The same class the send session's fail-fast offline error has,
            // so every downstream classification treats it as never sent.
            XCTAssertTrue(ConnectionErrorDetector.isPreTransmissionError(error))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertEqual(clock.sleeps, [30_000_000_000])
        XCTAssertEqual(monitor.suspendedWaiterCount, 0, "The losing path wait is unwound")
    }

    func testWaitForUsablePath_pathReturnsBeforeDeadline_returnsAndCancelsDeadline() async throws {
        let monitor = OutboundNetworkPathMonitor(manualPathSatisfied: false)
        let clock = ParkedSyncClock()
        let waiter = Task {
            try await OutboundConnectivityGate.waitForUsablePath(monitor: monitor, clock: clock)
        }
        await waitUntil { monitor.suspendedWaiterCount == 1 }

        // Revert-check: dropping the `waiters` resumption from
        // `OutboundNetworkPathMonitor.pathDidChange(isSatisfied:)` leaves the
        // gate parked, and this wait times out.
        monitor.pathDidChange(isSatisfied: true)
        await waitUntil { monitor.suspendedWaiterCount == 0 }
        if monitor.suspendedWaiterCount != 0 {
            // Unpark the stuck wait so a failing run ends instead of hanging.
            waiter.cancel()
        }
        try await waiter.value

        XCTAssertEqual(monitor.suspendedWaiterCount, 0)
        XCTAssertEqual(clock.sleeps.count, 1)
    }

    @MainActor
    func testWaitForUsablePath_cancelledWhileWaiting_throwsCancellationPromptly() async {
        let monitor = OutboundNetworkPathMonitor(manualPathSatisfied: false)
        let waiter = Task {
            try await OutboundConnectivityGate.waitForUsablePath(
                monitor: monitor,
                clock: ParkedSyncClock()
            )
        }
        var finished = false
        let watcher = Task { @MainActor in
            _ = try? await waiter.value
            finished = true
        }
        await waitUntil { monitor.suspendedWaiterCount == 1 }

        // Neither the path nor the deadline ever fires here.
        // Revert-check: dropping the `onCancel` handler from
        // `OutboundNetworkPathMonitor.waitUntilPathSatisfied` leaves the path
        // wait parked (the task group cannot exit), and this wait times out.
        waiter.cancel()
        await waitUntil { finished }
        if !finished {
            // Unpark the stuck wait so a failing run ends instead of hanging.
            monitor.pathDidChange(isSatisfied: true)
        }
        await watcher.value
        do {
            try await waiter.value
            XCTFail("A cancelled wait must not report a usable path")
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
        XCTAssertEqual(monitor.suspendedWaiterCount, 0)
    }

    func testWaitUntilPathSatisfied_unsatisfiedUpdateKeepsWaiterParked() async throws {
        let monitor = OutboundNetworkPathMonitor(manualPathSatisfied: false)
        let waiter = Task { try await monitor.waitUntilPathSatisfied() }
        await waitUntil { monitor.suspendedWaiterCount == 1 }

        monitor.pathDidChange(isSatisfied: false)
        XCTAssertEqual(monitor.suspendedWaiterCount, 1)
        XCTAssertTrue(monitor.isPathKnownUnsatisfied)

        monitor.pathDidChange(isSatisfied: true)
        try await waiter.value
        XCTAssertFalse(monitor.isPathKnownUnsatisfied)
    }

    private func waitUntil(
        timeout: TimeInterval = 2.0,
        pollIntervalNanoseconds: UInt64 = 10_000_000,
        file: StaticString = #filePath,
        line: UInt = #line,
        condition: @escaping () async -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() {
                return
            }
            try? await Task.sleep(nanoseconds: pollIntervalNanoseconds)
        }
        XCTFail("Timed out waiting for condition", file: file, line: line)
    }
}
