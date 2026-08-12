import XCTest
import BackgroundTasks
@testable import esc_chatmail

/// Exactly-once semantics for the background-task completion latch: expiration
/// records a forced failure, the worker's first `complete` invokes the callback,
/// and concurrent/later completions are ignored.
final class BackgroundTaskCompletionLatchTests: XCTestCase {

    func testFirstCompletionWinsAndLaterCallsAreIgnored() {
        var outcomes: [Bool] = []
        let latch = BackgroundTaskCompletionLatch { outcomes.append($0) }

        latch.complete(success: true)
        latch.complete(success: false)
        latch.complete(success: true)

        XCTAssertEqual(outcomes, [true])
    }

    func testExpirationDefersFailureUntilWorkerCompletion() {
        var outcomes: [Bool] = []
        let latch = BackgroundTaskCompletionLatch { outcomes.append($0) }

        latch.expire()
        XCTAssertTrue(outcomes.isEmpty, "Expiration must wait for worker cleanup")

        latch.complete(success: true)

        XCTAssertEqual(outcomes, [false])
    }

    func testExpirationAfterCompletionIsIgnored() {
        var outcomes: [Bool] = []
        let latch = BackgroundTaskCompletionLatch { outcomes.append($0) }

        latch.complete(success: true)
        latch.expire()

        XCTAssertEqual(outcomes, [true])
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

    func testCancellationLatchRemembersExpirationBeforeWorkerInstallation() {
        let cancellations = NSLockedCounter()
        let latch = BackgroundTaskCancellationLatch()

        latch.expire()
        latch.install { cancellations.increment() }
        latch.expire()

        XCTAssertEqual(cancellations.value, 1)
    }

    func testCancellationLatchCancelsInstalledWorkerExactlyOnce() {
        let cancellations = NSLockedCounter()
        let latch = BackgroundTaskCancellationLatch()

        latch.install { cancellations.increment() }
        latch.expire()
        latch.expire()

        XCTAssertEqual(cancellations.value, 1)
    }

    func testExpiredSchedulingGateRejectsSubmission() {
        let submissions = NSLockedCounter()
        let gate = BackgroundTaskSchedulingGate()

        gate.expire()
        let submitted = gate.submitIfActive { submissions.increment() }

        XCTAssertFalse(submitted)
        XCTAssertEqual(submissions.value, 0)
    }

    func testSharedLifecycleExpirationRejectsSchedulingAndForcesFailure() {
        let lifecycleState = BackgroundTaskLifecycleState()
        let submissions = NSLockedCounter()
        var outcomes: [Bool] = []
        let schedulingGate = BackgroundTaskSchedulingGate(
            lifecycleState: lifecycleState
        )
        let completionLatch = BackgroundTaskCompletionLatch(
            lifecycleState: lifecycleState
        ) { outcomes.append($0) }

        lifecycleState.expire()
        let submitted = schedulingGate.submitIfActive { submissions.increment() }
        completionLatch.complete(success: true)
        completionLatch.complete(success: false)
        lifecycleState.expire()

        XCTAssertFalse(submitted)
        XCTAssertEqual(submissions.value, 0)
        XCTAssertEqual(outcomes, [false])
    }

    func testPendingRequestQueryCancellationUnblocksAndIgnoresLateCallback() async {
        for query in PendingTaskQuery.allCases {
            let callbackProbe = PendingTaskRequestsCallbackProbe()
            let scheduler = BackgroundTaskScheduler(
                pendingTaskRequestsProvider: { callbackProbe.install($0) }
            )
            let completion = expectation(description: "Cancelled \(query) query returned")
            let result = NSLockedBoolean()
            let task = Task {
                let isPending: Bool
                switch query {
                case .appRefresh:
                    isPending = await scheduler.isAppRefreshTaskPending()
                case .processing:
                    isPending = await scheduler.isProcessingTaskPending()
                }
                result.set(isPending)
                completion.fulfill()
            }
            await waitUntilCallbackIsInstalled(on: callbackProbe)

            task.cancel()
            await fulfillment(of: [completion], timeout: 1.0)

            XCTAssertEqual(result.value, true, "Query: \(query)")
            callbackProbe.fire(requests: [])
            _ = await task.value
            XCTAssertEqual(result.value, true, "A late callback must not change the result")
        }
    }

    func testPendingRequestQueryReturnsSynchronousCallbackResults() async {
        let absentScheduler = BackgroundTaskScheduler { completion in
            completion([])
        }
        let pendingScheduler = BackgroundTaskScheduler { completion in
            completion([
                BGAppRefreshTaskRequest(identifier: "com.esc.inboxchat.refresh")
            ])
        }

        let absent = await absentScheduler.isAppRefreshTaskPending()
        let pending = await pendingScheduler.isAppRefreshTaskPending()

        XCTAssertFalse(absent)
        XCTAssertTrue(pending)
    }

    func testProcessingPendingRequestQueryMapsAsynchronousIdentifierResults() async {
        let matchingCallback = PendingTaskRequestsCallbackProbe()
        let matchingScheduler = BackgroundTaskScheduler(
            pendingTaskRequestsProvider: { matchingCallback.install($0) }
        )
        let matchingTask = Task {
            await matchingScheduler.isProcessingTaskPending()
        }
        await waitUntilCallbackIsInstalled(on: matchingCallback)
        matchingCallback.fire(requests: [
            BGProcessingTaskRequest(identifier: "com.esc.inboxchat.processing")
        ])

        let nonmatchingScheduler = BackgroundTaskScheduler { completion in
            completion([
                BGAppRefreshTaskRequest(identifier: "com.esc.inboxchat.refresh")
            ])
        }
        let matching = await matchingTask.value
        let nonmatching = await nonmatchingScheduler.isProcessingTaskPending()

        XCTAssertTrue(matching)
        XCTAssertFalse(nonmatching)
    }

    func testPendingRequestQueryPreCancelledBeforeContinuationInstallSkipsProvider() async {
        let callbackProbe = PendingTaskRequestsCallbackProbe()
        let scheduler = BackgroundTaskScheduler(
            pendingTaskRequestsProvider: { callbackProbe.install($0) }
        )
        let startGate = BackgroundTaskWorkerStartGate()
        let task = Task {
            await startGate.waitUntilOpen()
            return await scheduler.isProcessingTaskPending()
        }
        await waitUntilWorkerIsBlocked(on: startGate)

        task.cancel()
        startGate.open()
        let result = await task.value

        XCTAssertTrue(result)
        XCTAssertFalse(callbackProbe.hasCallback)
    }

    func testWorkerStartGateBlocksUntilCancellationRegistrationCompletes() async {
        let startGate = BackgroundTaskWorkerStartGate()
        let crossings = NSLockedCounter()
        let worker = Task {
            await startGate.waitUntilOpen()
            crossings.increment()
        }
        await waitUntilWorkerIsBlocked(on: startGate)

        XCTAssertEqual(crossings.value, 0)
        startGate.open()
        await worker.value

        XCTAssertEqual(crossings.value, 1)
    }

    func testPreRecordedExpirationCancelsWorkerBeforeStartGateOpens() async {
        let startGate = BackgroundTaskWorkerStartGate()
        let cancellationLatch = BackgroundTaskCancellationLatch()
        let work = NSLockedCounter()
        let worker = Task {
            await startGate.waitUntilOpen()
            guard !Task.isCancelled else { return }
            work.increment()
        }
        await waitUntilWorkerIsBlocked(on: startGate)

        cancellationLatch.expire()
        cancellationLatch.install { worker.cancel() }
        startGate.open()
        await worker.value

        XCTAssertEqual(work.value, 0)
    }

    private func waitUntilWorkerIsBlocked(
        on startGate: BackgroundTaskWorkerStartGate,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0..<1_000 {
            if startGate.hasWaitingWorker {
                return
            }
            await Task.yield()
        }
        XCTFail("Timed out waiting for worker start gate", file: file, line: line)
    }

    private func waitUntilCallbackIsInstalled(
        on probe: PendingTaskRequestsCallbackProbe,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0..<1_000 {
            if probe.hasCallback {
                return
            }
            await Task.yield()
        }
        XCTFail("Timed out waiting for pending-request callback", file: file, line: line)
    }
}

private enum PendingTaskQuery: CaseIterable {
    case appRefresh
    case processing
}

private final class PendingTaskRequestsCallbackProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var callback: (([BGTaskRequest]) -> Void)?

    var hasCallback: Bool {
        lock.lock()
        defer { lock.unlock() }
        return callback != nil
    }

    func install(_ callback: @escaping ([BGTaskRequest]) -> Void) {
        lock.lock()
        self.callback = callback
        lock.unlock()
    }

    func fire(requests: [BGTaskRequest]) {
        lock.lock()
        let callback = self.callback
        self.callback = nil
        lock.unlock()
        callback?(requests)
    }
}

private final class NSLockedBoolean: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue: Bool?

    var value: Bool? {
        lock.lock()
        defer { lock.unlock() }
        return storedValue
    }

    func set(_ value: Bool) {
        lock.lock()
        storedValue = value
        lock.unlock()
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
