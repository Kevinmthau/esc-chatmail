import XCTest
import BackgroundTasks
@testable import esc_chatmail

/// Drives `BackgroundTaskRegistry` through its injected `BGTaskScheduler`
/// seams: the real scheduler cannot back hosted unit tests because launch
/// handlers may only be registered during app launch and the simulator
/// rejects submits outright.
final class BackgroundTaskRegistryTests: XCTestCase {

    /// Records what the registry hands to the `BGTaskScheduler` seams.
    private final class SchedulerSpy {
        var submittedRequests: [BGTaskRequest] = []
        var pendingIdentifiers: Set<String> = []
        var pendingFetchCount = 0
    }

    private func makeRegistry(spy: SchedulerSpy) -> BackgroundTaskRegistry {
        BackgroundTaskRegistry(
            registerLaunchHandler: { _, _ in },
            submitTaskRequest: { spy.submittedRequests.append($0) },
            pendingTaskIdentifiers: {
                spy.pendingFetchCount += 1
                return spy.pendingIdentifiers
            }
        )
    }

    // Revert-check: fails if `BackgroundTaskRegistry.scheduleIfNotPending(_:)`
    // stops consulting `pendingTaskIdentifiers` before submitting (i.e.
    // degenerates back into plain `schedule(_:)`). A `BGTaskScheduler` submit
    // with an already-pending identifier REPLACES the pending request and
    // pushes its `earliestBeginDate` out by the full configured interval, so
    // an unconditional launch-path re-submit postpones the task forever for a
    // user who cold-launches more often than that interval.
    func testScheduleIfNotPending_pendingIdentifier_isNotResubmitted() async {
        let spy = SchedulerSpy()
        let registry = makeRegistry(spy: spy)
        registry.register(config: .dailyProcessing(identifier: "task.pending"), handler: { true })
        spy.pendingIdentifiers = ["task.pending"]

        await registry.scheduleIfNotPending(["task.pending"])

        XCTAssertTrue(
            spy.submittedRequests.isEmpty,
            "A still-pending request must not be replaced (and thereby postponed)"
        )
    }

    func testScheduleIfNotPending_identifierWithoutPendingRequest_submitsConfiguredRequest() async {
        let spy = SchedulerSpy()
        let registry = makeRegistry(spy: spy)
        registry.register(
            config: .weeklyProcessing(
                identifier: "task.vacuumlike",
                requiresNetwork: false,
                requiresPower: true
            ),
            handler: { true }
        )

        await registry.scheduleIfNotPending(["task.vacuumlike"])

        XCTAssertEqual(spy.submittedRequests.map(\.identifier), ["task.vacuumlike"])
        guard let processingRequest = spy.submittedRequests.first as? BGProcessingTaskRequest else {
            XCTFail("Expected a BGProcessingTaskRequest for a processing configuration")
            return
        }
        XCTAssertTrue(processingRequest.requiresExternalPower)
        XCTAssertFalse(processingRequest.requiresNetworkConnectivity)
    }

    // Revert-check: fails if `scheduleIfNotPending(_:)` fetches the pending
    // set per identifier instead of once per batch, or if it stops filtering
    // the batch through that set.
    func testScheduleIfNotPending_mixedBatch_submitsOnlyAbsentIdentifiersWithOneFetch() async {
        let spy = SchedulerSpy()
        let registry = makeRegistry(spy: spy)
        for identifier in ["task.a", "task.b", "task.c"] {
            registry.register(config: .dailyProcessing(identifier: identifier), handler: { true })
        }
        spy.pendingIdentifiers = ["task.b"]

        await registry.scheduleIfNotPending(["task.a", "task.b", "task.c"])

        XCTAssertEqual(spy.submittedRequests.map(\.identifier).sorted(), ["task.a", "task.c"])
        XCTAssertEqual(spy.pendingFetchCount, 1)
    }

    // HONEST SCOPE: `BGTask` has no public initializer, so the fired-task
    // path (`handleTask` → `schedule(_:)`) cannot be driven end to end here
    // and this test cannot fail if that call site alone is rerouted through
    // the pending guard. It pins the next-best seam: plain `schedule(_:)` —
    // the re-arm's callee — must stay an unconditional submit with no pending
    // fetch, because the fired request was just consumed and skipping the
    // re-submit would retire a recurring task after its first run.
    func testSchedule_identifierStillListedAsPending_submitsUnconditionally() async {
        let spy = SchedulerSpy()
        let registry = makeRegistry(spy: spy)
        registry.register(config: .dailyProcessing(identifier: "task.rearm"), handler: { true })
        spy.pendingIdentifiers = ["task.rearm"]

        registry.schedule("task.rearm")

        XCTAssertEqual(spy.submittedRequests.map(\.identifier), ["task.rearm"])
        XCTAssertEqual(
            spy.pendingFetchCount,
            0,
            "Plain schedule must not consult the pending fetch"
        )
    }

    func testScheduleIfNotPending_unregisteredIdentifier_submitsNothing() async {
        let spy = SchedulerSpy()
        let registry = makeRegistry(spy: spy)

        await registry.scheduleIfNotPending(["task.unknown"])

        XCTAssertTrue(spy.submittedRequests.isEmpty)
    }
}
