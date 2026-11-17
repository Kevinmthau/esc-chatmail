import XCTest
@testable import esc_chatmail

final class SyncRunCoordinatorTests: XCTestCase {
    func testBeginRunRejectsSecondRunUntilFirstEnds() async {
        let coordinator = SyncRunCoordinator()

        guard let firstRun = await coordinator.beginRun(kind: .foregroundIncremental) else {
            return XCTFail("Expected first run to start")
        }

        let secondRun = await coordinator.beginRun(kind: .background)
        XCTAssertNil(secondRun)
        let activeKindAfterSecondRun = await coordinator.activeRunKind()
        XCTAssertEqual(activeKindAfterSecondRun, .foregroundIncremental)

        await coordinator.endRun(firstRun)

        let thirdRun = await coordinator.beginRun(kind: .background)
        XCTAssertNotNil(thirdRun)
        let activeKindAfterThirdRun = await coordinator.activeRunKind()
        XCTAssertEqual(activeKindAfterThirdRun, .background)

        if let thirdRun {
            await coordinator.endRun(thirdRun)
        }
        let isRunning = await coordinator.isRunning()
        XCTAssertFalse(isRunning)
    }

    func testWaitUntilIdleResumesAfterRunEnds() async {
        let coordinator = SyncRunCoordinator()

        guard let run = await coordinator.beginRun(kind: .background) else {
            return XCTFail("Expected run to start")
        }

        let waiter = Task {
            await coordinator.waitUntilIdle()
            return true
        }

        await coordinator.endRun(run)

        let didResume = await waiter.value
        XCTAssertTrue(didResume)
    }

    func testCancelForegroundRunCancelsTaskButKeepsBoundaryUntilEnded() async {
        let coordinator = SyncRunCoordinator()

        guard let syncRunTask = await coordinator.beginRunWithTask(kind: .foregroundIncremental, taskBuilder: {
            Task {
                try await Task.sleep(nanoseconds: 60_000_000_000)
            }
        }) else {
            return XCTFail("Expected foreground task to start")
        }

        let didCancel = await coordinator.cancelForegroundRun()
        XCTAssertTrue(didCancel)

        do {
            try await syncRunTask.task.value
            XCTFail("Expected task cancellation")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Expected CancellationError, got \(error)")
        }

        let activeKindAfterCancel = await coordinator.activeRunKind()
        XCTAssertEqual(activeKindAfterCancel, .foregroundIncremental)

        await coordinator.endRun(syncRunTask.run)
        let isRunning = await coordinator.isRunning()
        XCTAssertFalse(isRunning)
    }

    func testCancelForegroundRunDoesNotCancelBackgroundRun() async {
        let coordinator = SyncRunCoordinator()

        guard let run = await coordinator.beginRun(kind: .background) else {
            return XCTFail("Expected background run to start")
        }

        let didCancel = await coordinator.cancelForegroundRun()
        XCTAssertFalse(didCancel)
        let activeKindAfterCancel = await coordinator.activeRunKind()
        XCTAssertEqual(activeKindAfterCancel, .background)

        await coordinator.endRun(run)
    }

    func testQuiescenceCancelsActiveTaskAndBlocksNewRunsUntilReleased() async {
        let coordinator = SyncRunCoordinator()
        guard let syncRunTask = await coordinator.beginRunWithTask(
            kind: .foregroundIncremental,
            taskBuilder: {
                Task {
                    try await Task.sleep(nanoseconds: 60_000_000_000)
                }
            }
        ) else {
            return XCTFail("Expected foreground task to start")
        }

        let quiescenceTask = Task {
            await coordinator.beginQuiescence()
        }
        do {
            try await syncRunTask.task.value
            XCTFail("Account teardown must cancel a cancellable active run")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Expected CancellationError, got \(error)")
        }

        await coordinator.endRun(syncRunTask.run)
        await quiescenceTask.value

        let blockedRun = await coordinator.beginRun(kind: .pendingActions)
        XCTAssertNil(blockedRun, "No account work may start during destructive cleanup")

        let idleWaiterResumed = LockedFlag()
        let waiter = Task {
            await coordinator.waitUntilIdle()
            idleWaiterResumed.set()
        }
        for _ in 0..<20 {
            await Task.yield()
        }
        XCTAssertFalse(
            idleWaiterResumed.isSet,
            "Waiters must stay parked while the boundary is quiesced"
        )

        await coordinator.endQuiescence()
        await waiter.value
        XCTAssertTrue(idleWaiterResumed.isSet)

        let resumedRun = await coordinator.beginRun(kind: .pendingActions)
        XCTAssertNotNil(resumedRun)
        if let resumedRun {
            await coordinator.endRun(resumedRun)
        }
    }

    // Revert-check: `SyncRunCoordinator.acquireRunWithTask`, which registers
    // the task with the run it takes. A run taken with `acquireRun` has no
    // task, and quiescence then cancels nothing.
    func testAcquireRunWithTask_waitsForTheBoundaryThenQuiescenceCancelsItsTask() async throws {
        let coordinator = SyncRunCoordinator()
        let beganRun = await coordinator.beginRun(kind: .foregroundIncremental)
        let activeRun = try XCTUnwrap(beganRun)
        let madeRequest = await coordinator.makeAccountWorkRequest()
        let request = try XCTUnwrap(madeRequest)
        let builtTask = LockedFlag()

        let acquisition = Task {
            await coordinator.acquireRunWithTask(kind: .maintenance, for: request) { _ in
                builtTask.set()
                return Task {
                    // Long enough to outlast the test, short enough that a
                    // task nothing cancels fails it and does not hang it.
                    try await Task.sleep(nanoseconds: 5_000_000_000)
                }
            }
        }
        let parked = await workIsWaiting(on: coordinator)
        XCTAssertTrue(parked, "The acquisition waits for the active run")
        XCTAssertFalse(builtTask.isSet, "The task is built only once the run is taken")

        await coordinator.endRun(activeRun)
        let acquired = await acquisition.value
        let maintenance = try XCTUnwrap(acquired)
        let activeKind = await coordinator.activeRunKind()
        XCTAssertEqual(activeKind, .maintenance)

        let quiescenceTask = Task {
            await coordinator.beginQuiescence()
        }
        do {
            try await maintenance.task.value
            XCTFail("Account teardown must cancel a maintenance run's task")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Expected CancellationError, got \(error)")
        }
        await coordinator.endRun(maintenance.run)
        await quiescenceTask.value
        await coordinator.endQuiescence()
    }

    // Revert-check: the `request.generation == accountGeneration` guard in
    // `SyncRunCoordinator.acquireRunWithTask`. Work queued for one account
    // must not build its task on the next account's store.
    func testAcquireRunWithTask_accountTransitionWhileWaiting_buildsNoTask() async throws {
        let coordinator = SyncRunCoordinator()
        let beganRun = await coordinator.beginRun(kind: .foregroundIncremental)
        let activeRun = try XCTUnwrap(beganRun)
        let madeRequest = await coordinator.makeAccountWorkRequest()
        let request = try XCTUnwrap(madeRequest)
        let builtTask = LockedFlag()

        let acquisition = Task {
            await coordinator.acquireRunWithTask(kind: .maintenance, for: request) { _ in
                builtTask.set()
                return Task {}
            }
        }
        let parked = await workIsWaiting(on: coordinator)
        XCTAssertTrue(parked, "The acquisition waits for the active run")
        let quiescenceTask = Task {
            await coordinator.beginQuiescence()
        }
        let quiescing = await waitUntil(timeout: 5) {
            await coordinator.makeAccountWorkRequest() == nil
        }
        XCTAssertTrue(quiescing, "The account transition has begun")
        await coordinator.endRun(activeRun)
        await quiescenceTask.value
        await coordinator.endQuiescence()

        let acquired = await acquisition.value
        XCTAssertNil(acquired)
        XCTAssertFalse(builtTask.isSet)
    }

    // Revert-check: `parkUntilIdleOrCancelled()` in
    // `SyncRunCoordinator.acquireRunWithTask`. Parked with `parkUntilIdle()`,
    // a cancelled acquisition stays parked until the run ahead of it ends.
    // Here that run is held past the deadline, so the acquisition has not
    // returned and the first assertion fails. A fired background task is
    // completed only once its handler has returned, so an expired
    // maintenance task parked this way stayed uncompleted for as long as the
    // sync ahead of it ran.
    func testAcquireRunWithTask_cancelledWhileWaiting_returnsBeforeTheRunAheadEnds() async throws {
        let coordinator = SyncRunCoordinator()
        let beganRun = await coordinator.beginRun(kind: .foregroundIncremental)
        let activeRun = try XCTUnwrap(beganRun)
        let madeRequest = await coordinator.makeAccountWorkRequest()
        let request = try XCTUnwrap(madeRequest)
        let builtTask = LockedFlag()
        let returned = LockedFlag()

        let acquisition = Task { () -> SyncRunTask? in
            let acquired = await coordinator.acquireRunWithTask(kind: .maintenance, for: request) { _ in
                builtTask.set()
                return Task {}
            }
            returned.set()
            return acquired
        }
        let parked = await workIsWaiting(on: coordinator)
        XCTAssertTrue(parked, "The acquisition waits for the active run")

        acquisition.cancel()
        let returnedWhileTheRunWasHeld = await waitUntil(timeout: 5) { returned.isSet }
        XCTAssertTrue(
            returnedWhileTheRunWasHeld,
            "A cancelled acquisition must not wait for the run ahead of it to end"
        )
        let activeKind = await coordinator.activeRunKind()
        XCTAssertEqual(activeKind, .foregroundIncremental, "The run ahead is untouched")

        // Ending the run resumes whoever is still parked. The cancelled
        // waiter was removed as it was resumed: left behind, its continuation
        // is resumed a second time here, which traps.
        await coordinator.endRun(activeRun)
        let acquired = await acquisition.value
        XCTAssertNil(acquired)
        XCTAssertFalse(builtTask.isSet, "No task is built for a cancelled acquisition")
        let nextRun = await coordinator.beginRun(kind: .background)
        XCTAssertNotNil(nextRun, "The boundary is free for the next run")
    }

    func testConcurrentQuiescenceOwnersAreSerializedWithoutReopeningRunBoundary() async {
        let coordinator = SyncRunCoordinator()
        await coordinator.beginQuiescence()

        let secondOwnerAcquired = LockedFlag()
        let secondOwner = Task {
            await coordinator.beginQuiescence()
            secondOwnerAcquired.set()
        }
        for _ in 0..<20 {
            await Task.yield()
        }
        XCTAssertFalse(secondOwnerAcquired.isSet)

        await coordinator.endQuiescence()
        await secondOwner.value
        XCTAssertTrue(secondOwnerAcquired.isSet)
        let blockedRun = await coordinator.beginRun(kind: .foregroundIncremental)
        XCTAssertNil(
            blockedRun,
            "Lease handoff must not expose a gap where account work can start"
        )

        await coordinator.endQuiescence()
        let resumedRun = await coordinator.beginRun(kind: .foregroundIncremental)
        XCTAssertNotNil(resumedRun)
        if let resumedRun {
            await coordinator.endRun(resumedRun)
        }
    }

    func testAccountWorkRequestIsInvalidatedByAccountTransition() async {
        let coordinator = SyncRunCoordinator()
        guard let staleRequest = await coordinator.makeAccountWorkRequest() else {
            return XCTFail("Expected account work to be requestable while idle")
        }

        await coordinator.beginQuiescence()
        await coordinator.endQuiescence()

        let staleRun = await coordinator.acquireRun(
            kind: .pendingActions,
            for: staleRequest
        )
        XCTAssertNil(
            staleRun,
            "Old-account work must not acquire the boundary after teardown"
        )

        guard let currentRequest = await coordinator.makeAccountWorkRequest() else {
            return XCTFail("Expected work to be requestable after teardown")
        }
        let currentRun = await coordinator.acquireRun(
            kind: .pendingActions,
            for: currentRequest
        )
        XCTAssertNotNil(currentRun)
        if let currentRun {
            await coordinator.endRun(currentRun)
        }
    }

    /// Revert-check: fails if `acquireAccountWorkLease(kind:for:)` is removed or
    /// reimplemented on top of the exclusive boundary (as `acquireRun` is) — the
    /// lease would then return nil or hang behind the active run.
    func testAccountWorkLeaseIsGrantedConcurrentlyWithActiveRun() async {
        let coordinator = SyncRunCoordinator()

        guard let syncRun = await coordinator.beginRun(kind: .foregroundInitial) else {
            return XCTFail("Expected the initial sync run to start")
        }
        guard let request = await coordinator.makeAccountWorkRequest() else {
            return XCTFail("Account work must be requestable while a sync run is active")
        }

        guard let lease = await coordinator.acquireAccountWorkLease(
            kind: .pendingActions,
            for: request
        ) else {
            return XCTFail("A local mutation must not wait behind an unrelated sync run")
        }

        // The lease is invisible to the exclusive single-flight boundary.
        let activeKind = await coordinator.activeRunKind()
        XCTAssertEqual(activeKind, .foregroundInitial)
        let blockedRun = await coordinator.beginRun(kind: .background)
        XCTAssertNil(blockedRun, "A lease must not open the exclusive boundary")

        await coordinator.endRun(lease)
        await coordinator.endRun(syncRun)
        let isRunning = await coordinator.isRunning()
        XCTAssertFalse(isRunning)
    }

    /// Revert-check: fails if `isActiveRun(_:)` drops its
    /// `accountWorkLeases.contains(run.id)` arm or if `endRun(_:)` stops
    /// removing leases. `PendingActionsManager.queueAction(within:)` validates
    /// the caller's lease through `isActiveRun(_:)`, so both halves are
    /// load-bearing.
    func testIsActiveRunValidatesAccountWorkLeaseUntilItIsReleased() async {
        let coordinator = SyncRunCoordinator()

        guard let request = await coordinator.makeAccountWorkRequest(),
              let lease = await coordinator.acquireAccountWorkLease(
                kind: .pendingActions,
                for: request
              ) else {
            return XCTFail("Expected an account-work lease on an idle coordinator")
        }

        let isActiveWhileHeld = await coordinator.isActiveRun(lease)
        XCTAssertTrue(isActiveWhileHeld)

        await coordinator.endRun(lease)
        let isActiveAfterRelease = await coordinator.isActiveRun(lease)
        XCTAssertFalse(isActiveAfterRelease)

        // A duplicate release must not clobber unrelated coordinator state.
        await coordinator.endRun(lease)
        let laterRun = await coordinator.beginRun(kind: .background)
        XCTAssertNotNil(laterRun, "Releasing a lease twice must not wedge the boundary")
        if let laterRun {
            await coordinator.endRun(laterRun)
        }
    }

    /// Revert-check: fails if `beginQuiescence()` returns while a non-exclusive
    /// lease is outstanding — for example if its drain loop is narrowed back to
    /// the exclusive run only. There is no active run here, so the old
    /// exclusive-only wait would return immediately and set the flag.
    func testQuiescenceDrainsOutstandingAccountWorkLeaseBeforeReturning() async {
        let coordinator = SyncRunCoordinator()

        guard let staleRequest = await coordinator.makeAccountWorkRequest(),
              let lease = await coordinator.acquireAccountWorkLease(
                kind: .pendingActions,
                for: staleRequest
              ) else {
            return XCTFail("Expected an account-work lease on an idle coordinator")
        }

        let transitionCompleted = LockedFlag()
        let transition = Task {
            await coordinator.beginQuiescence()
            transitionCompleted.set()
        }
        for _ in 0..<20 {
            await Task.yield()
        }
        XCTAssertFalse(
            transitionCompleted.isSet,
            "Account teardown must wait for outstanding account-work leases"
        )

        await coordinator.endRun(lease)
        await transition.value
        XCTAssertTrue(transitionCompleted.isSet)

        let staleLease = await coordinator.acquireAccountWorkLease(
            kind: .pendingActions,
            for: staleRequest
        )
        XCTAssertNil(
            staleLease,
            "Old-account work must not lease the boundary after teardown starts"
        )

        await coordinator.endQuiescence()
        guard let freshRequest = await coordinator.makeAccountWorkRequest() else {
            return XCTFail("Expected work to be requestable after teardown")
        }
        let freshLease = await coordinator.acquireAccountWorkLease(
            kind: .pendingActions,
            for: freshRequest
        )
        XCTAssertNotNil(freshLease)
        if let freshLease {
            await coordinator.endRun(freshLease)
        }
    }

    /// Revert-check for `resumeBoundaryDrainWaitersIfDrained()`: teardown must
    /// stay parked until *both* the exclusive run and every lease are released,
    /// whichever is released first. Fails if `beginQuiescence()` completes after
    /// only one of the two holders lets go.
    func testQuiescenceDrainsExclusiveRunAndLeaseInEitherReleaseOrder() async {
        // Lease released first, exclusive run still held.
        let leaseFirstCoordinator = SyncRunCoordinator()
        guard let heldRun = await leaseFirstCoordinator.beginRun(kind: .background) else {
            return XCTFail("Expected a background run to start")
        }
        guard let leaseFirstRequest = await leaseFirstCoordinator.makeAccountWorkRequest(),
              let leaseReleasedFirst = await leaseFirstCoordinator.acquireAccountWorkLease(
                kind: .pendingActions,
                for: leaseFirstRequest
              ) else {
            return XCTFail("Expected a lease alongside the background run")
        }

        let leaseFirstDrained = LockedFlag()
        let leaseFirstTransition = Task {
            await leaseFirstCoordinator.beginQuiescence()
            leaseFirstDrained.set()
        }

        await leaseFirstCoordinator.endRun(leaseReleasedFirst)
        for _ in 0..<20 {
            await Task.yield()
        }
        XCTAssertFalse(
            leaseFirstDrained.isSet,
            "Teardown must keep waiting while the exclusive run is still held"
        )

        await leaseFirstCoordinator.endRun(heldRun)
        await leaseFirstTransition.value
        XCTAssertTrue(leaseFirstDrained.isSet)
        await leaseFirstCoordinator.endQuiescence()

        // Mirrored ordering: exclusive run released first, lease still held.
        let runFirstCoordinator = SyncRunCoordinator()
        guard let runReleasedFirst = await runFirstCoordinator.beginRun(kind: .background) else {
            return XCTFail("Expected a background run to start")
        }
        guard let runFirstRequest = await runFirstCoordinator.makeAccountWorkRequest(),
              let heldLease = await runFirstCoordinator.acquireAccountWorkLease(
                kind: .pendingActions,
                for: runFirstRequest
              ) else {
            return XCTFail("Expected a lease alongside the background run")
        }

        let runFirstDrained = LockedFlag()
        let runFirstTransition = Task {
            await runFirstCoordinator.beginQuiescence()
            runFirstDrained.set()
        }

        await runFirstCoordinator.endRun(runReleasedFirst)
        for _ in 0..<20 {
            await Task.yield()
        }
        XCTAssertFalse(
            runFirstDrained.isSet,
            "Teardown must keep waiting while an account-work lease is still held"
        )

        await runFirstCoordinator.endRun(heldLease)
        await runFirstTransition.value
        XCTAssertTrue(runFirstDrained.isSet)
        await runFirstCoordinator.endQuiescence()
    }
}

extension SyncRunCoordinatorTests {
    /// Whether work parks behind `coordinator`'s boundary within the
    /// deadline. `waitUntilWorkIsWaiting()` awaited bare never returns when
    /// nothing parks: the test must fail on that, not hang.
    fileprivate func workIsWaiting(on coordinator: SyncRunCoordinator) async -> Bool {
        let parked = LockedFlag()
        Task {
            await coordinator.waitUntilWorkIsWaiting()
            parked.set()
        }
        return await waitUntil(timeout: 5) { parked.isSet }
    }

    fileprivate func waitUntil(
        timeout: TimeInterval,
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

private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var isSet: Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func set() {
        lock.lock()
        value = true
        lock.unlock()
    }
}
