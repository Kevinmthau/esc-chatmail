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
}
