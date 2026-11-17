#if os(iOS)
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

    private static let scheduledMaintenanceIdentifiers = [
        DatabaseMaintenanceService.analyzeTaskIdentifier,
        DatabaseMaintenanceService.cleanupTaskIdentifier
    ]

    private func makeService(spy: BackgroundTaskRegistrySchedulerSpy) -> DatabaseMaintenanceService {
        DatabaseMaintenanceService(taskRegistry: spy.makeRegistry())
    }

    // Revert-check: the `taskRegistry.retire(Self.retiredVacuumTaskIdentifier)`
    // call in `DatabaseMaintenanceService.registerBackgroundTasks()`. A device
    // that ran a build which scheduled the weekly vacuum can have a request
    // for it waiting, and `BGTaskScheduler` raises when it launches the app
    // for an identifier with no launch handler: the identifier must still be
    // registered, and the waiting request cancelled.
    func testInit_registersBothMaintenanceTasks_andKeepsAHandlerForTheRetiredVacuum() {
        let spy = BackgroundTaskRegistrySchedulerSpy()
        _ = makeService(spy: spy)

        XCTAssertEqual(
            spy.registeredIdentifiers.sorted(),
            (Self.scheduledMaintenanceIdentifiers + [DatabaseMaintenanceService.retiredVacuumTaskIdentifier]).sorted()
        )
        XCTAssertEqual(
            spy.cancelledIdentifiers,
            [DatabaseMaintenanceService.retiredVacuumTaskIdentifier],
            "The request an earlier build left with the system is cancelled"
        )
    }

    // Revert-check: register the vacuum identifier with
    // `register(config:handler:)` again in place of `retire`. `retire` gives
    // the identifier no configuration, so no schedule call can submit it,
    // whichever list it is named in.
    func testScheduleMaintenanceTasks_neverSubmitsTheRetiredVacuum() async {
        let spy = BackgroundTaskRegistrySchedulerSpy()
        let registry = spy.makeRegistry()
        let service = DatabaseMaintenanceService(taskRegistry: registry)

        await service.scheduleMaintenanceTasks()
        registry.schedule(DatabaseMaintenanceService.retiredVacuumTaskIdentifier)
        registry.scheduleAll()

        XCTAssertFalse(
            spy.submittedRequests.map(\.identifier).contains(DatabaseMaintenanceService.retiredVacuumTaskIdentifier)
        )
    }

    // Revert-check: fails if `DatabaseMaintenanceService.scheduleMaintenanceTasks()`
    // reverts to unconditional `taskRegistry.schedule(_:)` calls instead of
    // routing through `BackgroundTaskRegistry.scheduleIfNotPending(_:)`. The
    // unguarded shape re-submitted (and thereby REPLACED) every pending
    // request on every cold launch, so a user who launches daily perpetually
    // reset the 24h `earliestBeginDate` clocks and no maintenance task ever
    // became eligible to fire.
    func testScheduleMaintenanceTasks_allRequestsStillPending_replacesNothing() async {
        let spy = BackgroundTaskRegistrySchedulerSpy()
        let service = makeService(spy: spy)
        spy.pendingIdentifiers = Set(Self.scheduledMaintenanceIdentifiers)

        await service.scheduleMaintenanceTasks()

        XCTAssertTrue(
            spy.submittedRequests.isEmpty,
            "A cold launch must not replace still-pending maintenance requests"
        )
        XCTAssertEqual(spy.pendingFetchCount, 1, "One pending fetch serves both identifiers")
    }

    func testScheduleMaintenanceTasks_noRequestsPending_submitsBoth() async {
        let spy = BackgroundTaskRegistrySchedulerSpy()
        let service = makeService(spy: spy)

        await service.scheduleMaintenanceTasks()

        XCTAssertEqual(
            spy.submittedRequests.map(\.identifier).sorted(),
            Self.scheduledMaintenanceIdentifiers.sorted()
        )
    }

    func testScheduleMaintenanceTasks_partiallyPending_submitsOnlyAbsentRequests() async {
        let spy = BackgroundTaskRegistrySchedulerSpy()
        let service = makeService(spy: spy)
        spy.pendingIdentifiers = [DatabaseMaintenanceService.analyzeTaskIdentifier]

        await service.scheduleMaintenanceTasks()

        XCTAssertEqual(
            spy.submittedRequests.map(\.identifier),
            [DatabaseMaintenanceService.cleanupTaskIdentifier]
        )
    }
}
#endif
