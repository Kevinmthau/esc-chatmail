#if os(iOS)
import XCTest
import BackgroundTasks
@testable import esc_chatmail

/// Drives `BackgroundTaskRegistry` through its injected `BGTaskScheduler`
/// seams (`BackgroundTaskRegistrySchedulerSpy`): the real scheduler cannot
/// back hosted unit tests because the host app already registered every
/// identifier at launch — re-registering one aborts the process — and the
/// simulator rejects submits outright.
final class BackgroundTaskRegistryTests: XCTestCase {

    // Revert-check: fails if `BackgroundTaskRegistry.scheduleIfNotPending(_:)`
    // stops consulting `pendingTaskIdentifiers` before submitting (i.e.
    // degenerates back into plain `schedule(_:)`). A `BGTaskScheduler` submit
    // with an already-pending identifier REPLACES the pending request and
    // pushes its `earliestBeginDate` out by the full configured interval, so
    // an unconditional launch-path re-submit postpones the task forever for a
    // user who cold-launches more often than that interval.
    func testScheduleIfNotPending_pendingIdentifier_isNotResubmitted() async {
        let spy = BackgroundTaskRegistrySchedulerSpy()
        let registry = spy.makeRegistry()
        registry.register(config: .dailyProcessing(identifier: "task.pending"), handler: { true })
        spy.pendingIdentifiers = ["task.pending"]

        await registry.scheduleIfNotPending(["task.pending"])

        XCTAssertTrue(
            spy.submittedRequests.isEmpty,
            "A still-pending request must not be replaced (and thereby postponed)"
        )
    }

    func testScheduleIfNotPending_identifierWithoutPendingRequest_submitsConfiguredRequest() async {
        let spy = BackgroundTaskRegistrySchedulerSpy()
        let registry = spy.makeRegistry()
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
        let spy = BackgroundTaskRegistrySchedulerSpy()
        let registry = spy.makeRegistry()
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
        let spy = BackgroundTaskRegistrySchedulerSpy()
        let registry = spy.makeRegistry()
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
        let spy = BackgroundTaskRegistrySchedulerSpy()
        let registry = spy.makeRegistry()

        await registry.scheduleIfNotPending(["task.unknown"])

        XCTAssertTrue(spy.submittedRequests.isEmpty)
    }

    // MARK: - A fired task

    // Revert-check: `BackgroundTaskRegistry.runTaskOperation`. Its
    // expiration handler cancels the handler's task (drop
    // `cancellationLatch.expire()` and the handler never sees the
    // cancellation, so it runs to its own deadline) and leaves the completion
    // to the handler's return (complete from the expiration handler, as the
    // code before did, and the task is completed twice, the first time while
    // the handler still runs).
    func testRunTaskOperation_expiration_cancelsTheHandlerAndCompletesOnceAfterItReturns() async {
        let spy = BackgroundTaskRegistrySchedulerSpy()
        let registry = spy.makeRegistry()
        registry.register(config: .dailyProcessing(identifier: "task.expiring"), handler: { true })
        let run = FiredTaskRecorder()
        let handlerStarted = expectation(description: "handler started")
        let completed = expectation(description: "task completed")
        var expire: (() -> Void)?

        registry.runTaskOperation(
            identifier: "task.expiring",
            handler: {
                handlerStarted.fulfill()
                // Stands in for a maintenance pass: it stops when it is
                // cancelled, and reports success anyway.
                let deadline = Date().addingTimeInterval(5)
                while !Task.isCancelled, Date() < deadline {
                    try? await Task.sleep(nanoseconds: 2_000_000)
                }
                run.handlerReturned(sawCancellation: Task.isCancelled)
                return true
            },
            installExpirationHandler: { expire = $0 },
            onComplete: { success in
                run.completed(success: success)
                completed.fulfill()
            }
        )
        await fulfillment(of: [handlerStarted], timeout: 2)
        XCTAssertTrue(run.completions.isEmpty)

        expire?()
        XCTAssertTrue(
            run.completions.isEmpty || run.didHandlerReturn,
            "Expiration must not complete the task while its handler still runs"
        )
        await fulfillment(of: [completed], timeout: 4)

        XCTAssertTrue(run.sawCancellation, "Expiration cancels the handler's task")
        XCTAssertEqual(run.completions, [false], "Completed once, and an expired task is a failed one")
        XCTAssertTrue(run.handlerReturnedBeforeCompletion)
    }

    // Revert-check: the order of `self.schedule(identifier)` and
    // `completionLatch.complete(success:)` in `runTaskOperation`. iOS may
    // suspend the process as soon as the task is completed, so the next
    // request has to be with the system by then.
    func testRunTaskOperation_handlerFinishes_rearmsBeforeItCompletes() async {
        let spy = BackgroundTaskRegistrySchedulerSpy()
        let registry = spy.makeRegistry()
        registry.register(config: .dailyProcessing(identifier: "task.finishing"), handler: { true })
        let run = FiredTaskRecorder()
        let completed = expectation(description: "task completed")

        registry.runTaskOperation(
            identifier: "task.finishing",
            handler: { true },
            installExpirationHandler: { _ in },
            onComplete: { success in
                run.completed(success: success, submittedSoFar: spy.submittedRequests.map(\.identifier))
                completed.fulfill()
            }
        )
        await fulfillment(of: [completed], timeout: 2)

        XCTAssertEqual(run.completions, [true])
        XCTAssertEqual(run.submittedAtCompletion, ["task.finishing"])
    }

    // Revert-check: `BackgroundTaskRegistry.retire`. It registers a launch
    // handler and cancels the waiting request, and gives the identifier no
    // configuration, so no schedule call can submit it again.
    func testRetire_keepsALaunchHandlerCancelsThePendingRequestAndCannotBeScheduled() async {
        let spy = BackgroundTaskRegistrySchedulerSpy()
        let registry = spy.makeRegistry()

        registry.retire("task.retired")
        registry.schedule("task.retired")
        await registry.scheduleIfNotPending(["task.retired"])
        registry.scheduleAll()

        XCTAssertEqual(spy.registeredIdentifiers, ["task.retired"])
        XCTAssertEqual(spy.cancelledIdentifiers, ["task.retired"])
        XCTAssertTrue(spy.submittedRequests.isEmpty)
    }
}

/// What a fired task's handler and completion did, in order.
///
/// `@unchecked Sendable`: every read and write is made under `lock`.
private final class FiredTaskRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var completionResults: [Bool] = []
    private var handlerDidReturn = false
    private var handlerSawCancellation = false
    private var returnedBeforeCompletion = false
    private var submitted: [String] = []

    func handlerReturned(sawCancellation: Bool) {
        lock.lock()
        defer { lock.unlock() }
        handlerDidReturn = true
        handlerSawCancellation = sawCancellation
    }

    func completed(success: Bool, submittedSoFar: [String] = []) {
        lock.lock()
        defer { lock.unlock() }
        if completionResults.isEmpty {
            returnedBeforeCompletion = handlerDidReturn
            submitted = submittedSoFar
        }
        completionResults.append(success)
    }

    var completions: [Bool] { lock.lock(); defer { lock.unlock() }; return completionResults }
    var didHandlerReturn: Bool { lock.lock(); defer { lock.unlock() }; return handlerDidReturn }
    var sawCancellation: Bool { lock.lock(); defer { lock.unlock() }; return handlerSawCancellation }
    var handlerReturnedBeforeCompletion: Bool { lock.lock(); defer { lock.unlock() }; return returnedBeforeCompletion }
    var submittedAtCompletion: [String] { lock.lock(); defer { lock.unlock() }; return submitted }
}
#endif
