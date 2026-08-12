import XCTest
import BackgroundTasks
@testable import esc_chatmail

/// Pins the cold-launch maintenance scheduling path. `initializeApp()` calls
/// `scheduleMaintenanceTasks()` on every cold launch, and a `BGTaskScheduler`
/// submit with an already-pending identifier REPLACES that request — so an
/// unguarded launch path pushed cleanup/analyze eligibility past every
/// overnight maintenance window for a daily-launch user, and the cleanup
/// task's `PersistentHistoryPurger` never ran at all.
@MainActor
final class DatabaseMaintenanceSchedulingTests: XCTestCase {

    private static let allMaintenanceIdentifiers = [
        DatabaseMaintenanceService.vacuumTaskIdentifier,
        DatabaseMaintenanceService.analyzeTaskIdentifier,
        DatabaseMaintenanceService.cleanupTaskIdentifier
    ]

    private func makeService(spy: BackgroundTaskRegistrySchedulerSpy) -> DatabaseMaintenanceService {
        DatabaseMaintenanceService(taskRegistry: spy.makeRegistry())
    }

    func testInit_registersAllThreeMaintenanceTasks() {
        let spy = BackgroundTaskRegistrySchedulerSpy()
        _ = makeService(spy: spy)

        XCTAssertEqual(
            spy.registeredIdentifiers.sorted(),
            Self.allMaintenanceIdentifiers.sorted()
        )
    }

    // Revert-check: fails if `DatabaseMaintenanceService.scheduleMaintenanceTasks()`
    // reverts to unconditional `taskRegistry.schedule(_:)` calls instead of
    // routing through `BackgroundTaskRegistry.scheduleIfNotPending(_:)`. The
    // unguarded shape re-submitted (and thereby REPLACED) all three pending
    // requests on every cold launch, so a user who launches daily perpetually
    // reset the 24h/7d `earliestBeginDate` clocks and no maintenance task ever
    // became eligible to fire.
    func testScheduleMaintenanceTasks_allRequestsStillPending_replacesNothing() async {
        let spy = BackgroundTaskRegistrySchedulerSpy()
        let service = makeService(spy: spy)
        spy.pendingIdentifiers = Set(Self.allMaintenanceIdentifiers)

        await service.scheduleMaintenanceTasks()

        XCTAssertTrue(
            spy.submittedRequests.isEmpty,
            "A cold launch must not replace still-pending maintenance requests"
        )
        XCTAssertEqual(spy.pendingFetchCount, 1, "One pending fetch serves all three identifiers")
    }

    func testScheduleMaintenanceTasks_noRequestsPending_submitsAllThree() async {
        let spy = BackgroundTaskRegistrySchedulerSpy()
        let service = makeService(spy: spy)

        await service.scheduleMaintenanceTasks()

        XCTAssertEqual(
            spy.submittedRequests.map(\.identifier).sorted(),
            Self.allMaintenanceIdentifiers.sorted()
        )
    }

    func testScheduleMaintenanceTasks_partiallyPending_submitsOnlyAbsentRequests() async {
        let spy = BackgroundTaskRegistrySchedulerSpy()
        let service = makeService(spy: spy)
        spy.pendingIdentifiers = [DatabaseMaintenanceService.analyzeTaskIdentifier]

        await service.scheduleMaintenanceTasks()

        XCTAssertEqual(
            spy.submittedRequests.map(\.identifier).sorted(),
            [
                DatabaseMaintenanceService.cleanupTaskIdentifier,
                DatabaseMaintenanceService.vacuumTaskIdentifier
            ].sorted()
        )
    }
}
