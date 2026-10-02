import Network
import XCTest
@testable import esc_chatmail

/// `OutboundNetworkPathMonitor`'s mapping from `NWPath.Status` to "known
/// unsatisfied". `NWPath` itself cannot be constructed in a test, so the
/// mapping is exercised through `isUsable(_:)`, the exact function the system
/// monitor's `pathUpdateHandler` feeds into `pathDidChange(isSatisfied:)`.
final class OutboundNetworkPathMonitorTests: XCTestCase {
    func testIsUsable_requiresConnection_isNotKnownUnsatisfied() {
        // An idle VPN On Demand tunnel: only a connection attempt brings it
        // up, and the gate never makes one.
        // Revert-check: mapping `.requiresConnection` to false in
        // `OutboundNetworkPathMonitor.isUsable(_:)` (the retired
        // `path.status == .satisfied`) fails this, and every such send waited
        // out `sendConnectivityWaitTimeout` and failed without trying.
        XCTAssertTrue(OutboundNetworkPathMonitor.isUsable(.requiresConnection))
    }

    func testIsUsable_satisfiedAndUnsatisfied_mapDirectly() {
        XCTAssertTrue(OutboundNetworkPathMonitor.isUsable(.satisfied))
        XCTAssertFalse(OutboundNetworkPathMonitor.isUsable(.unsatisfied))
    }

    func testWaitForUsablePath_requiresConnectionPath_proceedsWithoutStartingDeadline() async throws {
        let monitor = OutboundNetworkPathMonitor(manualPathSatisfied: nil)
        monitor.pathDidChange(isSatisfied: OutboundNetworkPathMonitor.isUsable(.requiresConnection))
        let clock = FakeSyncClock()

        // The send goes ahead so its own request can activate the path; the
        // fail-fast session's pre-transmission -1009 still covers a path that
        // turns out to be genuinely offline.
        try await OutboundConnectivityGate.waitForUsablePath(monitor: monitor, clock: clock)

        XCTAssertFalse(monitor.isPathKnownUnsatisfied)
        XCTAssertTrue(clock.sleeps.isEmpty)
        XCTAssertEqual(monitor.suspendedWaiterCount, 0)
    }

    func testPathDidChange_unsatisfiedStatus_isKnownUnsatisfied() {
        let monitor = OutboundNetworkPathMonitor(manualPathSatisfied: nil)
        monitor.pathDidChange(isSatisfied: OutboundNetworkPathMonitor.isUsable(.unsatisfied))

        XCTAssertTrue(monitor.isPathKnownUnsatisfied)
    }
}
