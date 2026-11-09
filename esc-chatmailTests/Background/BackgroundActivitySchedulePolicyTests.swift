import XCTest
@testable import esc_chatmail

/// Pins the timing rules the Mac's `BackgroundActivityTaskRegistry` runs the
/// maintenance jobs by. The registry itself is Mac-only; the rules are pure.
final class BackgroundActivitySchedulePolicyTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)
    private let day: TimeInterval = 24 * 60 * 60
    private let week: TimeInterval = 7 * 24 * 60 * 60

    // MARK: - Due date

    func testDueDate_noStoredDate_isOneIntervalFromNow() {
        XCTAssertEqual(
            BackgroundActivitySchedulePolicy.dueDate(stored: nil, jobInterval: week, now: now),
            now.addingTimeInterval(week)
        )
    }

    // Revert-check: fails if `BackgroundActivitySchedulePolicy.dueDate(stored:...)`
    // starts a fresh interval at every launch instead of resuming the stored
    // date. That is the Mac form of the iOS REPLACES bug: a user who relaunches
    // more often than weekly would never see the vacuum run.
    func testDueDate_storedDateWithinInterval_isKept() {
        let stored = now.addingTimeInterval(2 * day)
        XCTAssertEqual(
            BackgroundActivitySchedulePolicy.dueDate(stored: stored, jobInterval: week, now: now),
            stored
        )
    }

    func testDueDate_storedDateInThePast_isKeptSoTheJobRunsSoon() {
        let stored = now.addingTimeInterval(-3 * day)
        XCTAssertEqual(
            BackgroundActivitySchedulePolicy.dueDate(stored: stored, jobInterval: day, now: now),
            stored
        )
    }

    // Revert-check: fails if `BackgroundActivitySchedulePolicy.dueDate(stored:...)`
    // stops clamping. A due date stored before the clock was set back would
    // otherwise hold the job off for longer than its own interval.
    func testDueDate_storedDateBeyondOneInterval_isPulledInToOneInterval() {
        let stored = now.addingTimeInterval(30 * day)
        XCTAssertEqual(
            BackgroundActivitySchedulePolicy.dueDate(stored: stored, jobInterval: week, now: now),
            now.addingTimeInterval(week)
        )
    }

    func testDueDateAfterRun_isOneIntervalAfterTheRunFinished() {
        XCTAssertEqual(
            BackgroundActivitySchedulePolicy.dueDate(afterRunFinishedAt: now, jobInterval: day),
            now.addingTimeInterval(day)
        )
    }

    // MARK: - Activity timing

    // Revert-check: fails if `BackgroundActivitySchedulePolicy.activityTiming`
    // stops adding the tolerance to the delay. A one-shot activity may run as
    // early as `interval - tolerance`, so the job would run before it is due.
    func testActivityTiming_notYetDue_neverRunsBeforeTheDueDate() {
        let dueDate = now.addingTimeInterval(3 * day)
        let timing = BackgroundActivitySchedulePolicy.activityTiming(dueDate: dueDate, jobInterval: week, now: now)

        XCTAssertEqual(timing.interval - timing.tolerance, 3 * day)
        XCTAssertEqual(timing.tolerance, BackgroundActivitySchedulePolicy.maximumTolerance)
    }

    func testActivityTiming_overdue_waitsTheMinimumDelay() {
        let dueDate = now.addingTimeInterval(-day)
        let timing = BackgroundActivitySchedulePolicy.activityTiming(dueDate: dueDate, jobInterval: day, now: now)

        XCTAssertEqual(timing.interval - timing.tolerance, BackgroundActivitySchedulePolicy.minimumDelay)
    }

    func testActivityTiming_dueSoonerThanTheMinimumDelay_waitsTheMinimumDelay() {
        let dueDate = now.addingTimeInterval(60)
        let timing = BackgroundActivitySchedulePolicy.activityTiming(dueDate: dueDate, jobInterval: day, now: now)

        XCTAssertEqual(timing.interval - timing.tolerance, BackgroundActivitySchedulePolicy.minimumDelay)
    }

    func testActivityTiming_shortJobInterval_scalesTheToleranceDown() {
        let jobInterval: TimeInterval = 2 * 60 * 60
        let timing = BackgroundActivitySchedulePolicy.activityTiming(
            dueDate: now.addingTimeInterval(jobInterval),
            jobInterval: jobInterval,
            now: now
        )

        XCTAssertEqual(timing.tolerance, jobInterval / 4)
    }

    // MARK: - Deferral

    func testShouldDefer_systemRequestsDeferral_defers() {
        XCTAssertTrue(
            BackgroundActivitySchedulePolicy.shouldDefer(
                systemRequestsDeferral: true,
                requiresExternalPower: false,
                isOnExternalPower: true
            )
        )
    }

    // Revert-check: fails if `BackgroundActivitySchedulePolicy.shouldDefer`
    // ignores `requiresExternalPower`, which the weekly vacuum sets: it would
    // then run on battery, unlike its iOS `BGProcessingTaskRequest`.
    func testShouldDefer_powerRequiredOnBattery_defers() {
        XCTAssertTrue(
            BackgroundActivitySchedulePolicy.shouldDefer(
                systemRequestsDeferral: false,
                requiresExternalPower: true,
                isOnExternalPower: false
            )
        )
    }

    func testShouldDefer_powerRequiredOnACPower_runs() {
        XCTAssertFalse(
            BackgroundActivitySchedulePolicy.shouldDefer(
                systemRequestsDeferral: false,
                requiresExternalPower: true,
                isOnExternalPower: true
            )
        )
    }

    func testShouldDefer_powerNotRequiredOnBattery_runs() {
        XCTAssertFalse(
            BackgroundActivitySchedulePolicy.shouldDefer(
                systemRequestsDeferral: false,
                requiresExternalPower: false,
                isOnExternalPower: false
            )
        )
    }
}
