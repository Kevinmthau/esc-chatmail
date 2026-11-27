import XCTest
import Network
@testable import esc_chatmail

/// Sync's network path: what a run may start on, written in the update's own
/// call, and an edge any number of callers can hear when the path comes back
/// (architecture review 2026-11, background-energy#5).
///
/// HONEST SCOPE: the path is manual. How close together `NWPathMonitor`
/// delivers updates, and what a real VPN On Demand tunnel reports, were not
/// measured.
final class NetworkMonitorServiceTests: XCTestCase {

    /// Only a path known to be unsatisfied refuses a run. A path not reported
    /// yet, and one that requires a connection (an idle VPN On Demand tunnel,
    /// which the request itself brings up), read usable.
    ///
    /// Revert-check: the `guard let status else { return true }` in
    /// `NetworkMonitorService.isUsable` (as `false`, the first assertion
    /// fails), and its `OutboundNetworkPathMonitor.isUsable` (as
    /// `status == .satisfied`, `.requiresConnection` reads unusable).
    func testIsPathUsable_isFalseOnlyForAKnownUnsatisfiedPath() {
        XCTAssertTrue(NetworkMonitorService(manualStatus: nil).isPathUsable, "Not reported yet")
        XCTAssertTrue(NetworkMonitorService(manualStatus: .satisfied).isPathUsable)
        XCTAssertTrue(NetworkMonitorService(manualStatus: .requiresConnection).isPathUsable)
        XCTAssertFalse(NetworkMonitorService(manualStatus: .unsatisfied).isPathUsable)
    }

    /// The status is the last update's as soon as the update's call returns.
    /// It was written through a new `Task` for each update, which run in no
    /// set order, so the flag could be left reading "no network" on a link
    /// that was up.
    ///
    /// Revert-check: the synchronous write in
    /// `NetworkMonitorService.pathDidChange(to:isExpensive:)` (moved into a
    /// `Task`, a read right after an update sees the one before it).
    func testPathDidChange_isReadInTheSameCall() {
        let monitor = NetworkMonitorService(manualStatus: .satisfied)

        for _ in 0..<50 {
            monitor.pathDidChange(to: .unsatisfied)
            XCTAssertFalse(monitor.isPathUsable)
            monitor.pathDidChange(to: .satisfied)
            XCTAssertTrue(monitor.isPathUsable)
        }
    }

    /// Every subscriber hears the path come back, once for each return; a
    /// path that was usable already returns nothing.
    ///
    /// Revert-check: the `guard !wasUsable` in
    /// `NetworkMonitorService.pathDidChange(to:isExpensive:)` (every update
    /// yields, so the first-report and still-up updates are heard too), and
    /// `Array(subscribers.values)` there (as the first subscriber alone, the
    /// second hears nothing).
    func testUsablePathReturns_yieldToEverySubscriberOnlyWhenADownPathComesBack() async {
        let monitor = NetworkMonitorService(manualStatus: nil)
        let first = EdgeCounter(stream: monitor.usablePathReturns())
        let second = EdgeCounter(stream: monitor.usablePathReturns())

        monitor.pathDidChange(to: .satisfied) // the first report: no return
        monitor.pathDidChange(to: .satisfied) // still up: no return
        // Long enough for a subscriber to drain anything yielded; the stream
        // keeps the newest edge, so two edges heard late would read as one.
        try? await Task.sleep(nanoseconds: 100_000_000)
        let heardBeforeAnyReturn = await first.count + second.count
        XCTAssertEqual(heardBeforeAnyReturn, 0, "A path that was never down returns nothing")
        monitor.pathDidChange(to: .unsatisfied)
        monitor.pathDidChange(to: .requiresConnection) // usable again: a return

        let bothHeardIt = await waitUntil {
            let heardByFirst = await first.count
            let heardBySecond = await second.count
            return heardByFirst == 1 && heardBySecond == 1
        }
        XCTAssertTrue(bothHeardIt)
        monitor.pathDidChange(to: .unsatisfied)
        monitor.pathDidChange(to: .satisfied)
        let bothHeardTheSecond = await waitUntil {
            let heardByFirst = await first.count
            let heardBySecond = await second.count
            return heardByFirst == 2 && heardBySecond == 2
        }
        XCTAssertTrue(bothHeardTheSecond)
        try? await Task.sleep(nanoseconds: 50_000_000)
        let firstCount = await first.count
        let secondCount = await second.count
        XCTAssertEqual(firstCount, 2, "Nothing else was a return")
        XCTAssertEqual(secondCount, 2)
        first.stop()
        second.stop()
    }

    /// A subscriber that stops listening is dropped; the others keep hearing.
    ///
    /// Revert-check: the `onTermination` in
    /// `NetworkMonitorService.usablePathReturns()` (the ended subscriber is
    /// kept and the count stays at two).
    func testUsablePathReturns_endedSubscriptionIsDropped() async {
        let monitor = NetworkMonitorService(manualStatus: .unsatisfied)
        let ended = EdgeCounter(stream: monitor.usablePathReturns())
        let kept = EdgeCounter(stream: monitor.usablePathReturns())
        XCTAssertEqual(monitor.subscriberCount, 2)

        ended.stop()
        let dropped = await waitUntil { monitor.subscriberCount == 1 }
        XCTAssertTrue(dropped)
        monitor.pathDidChange(to: .satisfied)

        let keptHeardIt = await waitUntil { await kept.count == 1 }
        XCTAssertTrue(keptHeardIt)
        let endedCount = await ended.count
        XCTAssertEqual(endedCount, 0)
        kept.stop()
    }

    private func waitUntil(
        timeout: TimeInterval = 5,
        pollIntervalNanoseconds: UInt64 = 5_000_000,
        condition: () async -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return true }
            try? await Task.sleep(nanoseconds: pollIntervalNanoseconds)
        }
        return await condition()
    }
}

/// Counts what one subscription hears until it is stopped.
private final class EdgeCounter: Sendable {
    private let counts: Counter
    private let task: Task<Void, Never>

    init(stream: AsyncStream<Void>) {
        let counts = Counter()
        self.counts = counts
        task = Task {
            for await _ in stream {
                await counts.increment()
            }
        }
    }

    var count: Int {
        get async { await counts.value }
    }

    func stop() {
        task.cancel()
    }
}

private actor Counter {
    private(set) var value = 0

    func increment() {
        value += 1
    }
}
