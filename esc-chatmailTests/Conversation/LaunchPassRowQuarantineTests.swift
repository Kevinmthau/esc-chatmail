import XCTest
@testable import esc_chatmail

/// A row an earlier launch died on is counted, and quarantined at the third
/// death; nothing else the guard sees counts as a death.
final class LaunchPassRowQuarantineTests: XCTestCase {
    private let passKey = "launchPassRowQuarantineTests.pass"
    private var store: InMemoryMigrationFlagStore!

    override func setUp() {
        super.setUp()
        store = InMemoryMigrationFlagStore()
    }

    override func tearDown() {
        store = nil
        super.tearDown()
    }

    /// A launch that marks `row` and ends without clearing the mark.
    private func dieDeriving(_ row: String, launch: String) {
        let guardForLaunch = LaunchPassRowQuarantine.recoveringFromEarlierLaunches(
            passKey: passKey,
            store: store,
            launchID: launch
        )
        guardForLaunch.beginRow(row)
    }

    private func recover(launch: String) -> LaunchPassRowQuarantine {
        LaunchPassRowQuarantine.recoveringFromEarlierLaunches(passKey: passKey, store: store, launchID: launch)
    }

    // Revert-check: the `deaths >= deathsBeforeQuarantine` branch in
    // `LaunchPassRowQuarantine.recoveringFromEarlierLaunches` (the row is never
    // quarantined), and the death count above it (each launch then starts from none).
    func testRowInFlightAtThreeDeaths_isQuarantined() {
        dieDeriving("R", launch: "1")
        XCTAssertFalse(recover(launch: "2").isQuarantined("R"))
        dieDeriving("R", launch: "2")
        XCTAssertFalse(recover(launch: "3").isQuarantined("R"))
        dieDeriving("R", launch: "3")
        let afterThird = recover(launch: "4")
        XCTAssertTrue(afterThird.isQuarantined("R"))
        XCTAssertFalse(afterThird.isQuarantined("S"))
        XCTAssertNil(store.string(forKey: LaunchPassRowQuarantine.inFlightKey(forPassKey: passKey)))
        XCTAssertNil(store.string(forKey: LaunchPassRowQuarantine.deathsKey(forPassKey: passKey)))
        XCTAssertTrue(recover(launch: "5").isQuarantined("R"), "A quarantine lasts")
    }

    /// Deaths on different rows are each one row's, never added together: a
    /// force quit lands on whichever row was in flight.
    /// Revert-check: the `$0 == row` filter on the death count in
    /// `recoveringFromEarlierLaunches` (the third row is then quarantined).
    func testDeathsOnDifferentRows_doNotAddUp() {
        dieDeriving("R", launch: "1")
        dieDeriving("S", launch: "2")
        dieDeriving("T", launch: "3")
        let next = recover(launch: "4")
        XCTAssertFalse(next.isQuarantined("R"))
        XCTAssertFalse(next.isQuarantined("S"))
        XCTAssertFalse(next.isQuarantined("T"))
    }

    // Revert-check: the `markLaunch != launchID` test in
    // `recoveringFromEarlierLaunches` (a pass that starts again in the same launch
    // then counts its own mark).
    func testMarkFromThisLaunch_isNotADeath() {
        for _ in 0..<5 {
            dieDeriving("R", launch: "same")
        }
        XCTAssertFalse(recover(launch: "same").isQuarantined("R"))
        XCTAssertNil(store.string(forKey: LaunchPassRowQuarantine.deathsKey(forPassKey: passKey)))
    }

    // Revert-check: the clearing write in `LaunchPassRowQuarantine.endRow`
    // (every launch's finished row then counts as a death).
    func testEndRow_clearsTheMark_soAFinishedRowIsNeverCounted() {
        for launch in ["1", "2", "3"] {
            let guardForLaunch = recover(launch: launch)
            guardForLaunch.beginRow("R")
            guardForLaunch.endRow()
        }
        XCTAssertFalse(recover(launch: "4").isQuarantined("R"))
        XCTAssertNil(store.string(forKey: LaunchPassRowQuarantine.inFlightKey(forPassKey: passKey)))
    }

    // Revert-check: the `suffix(maximumRememberedRows)` on the quarantined list
    // in `recoveringFromEarlierLaunches`.
    func testRememberedRows_areBounded() {
        let limit = LaunchPassRowQuarantine.maximumRememberedRows
        var launch = 0
        for row in 0..<(limit + 10) {
            for _ in 0..<LaunchPassRowQuarantine.deathsBeforeQuarantine {
                launch += 1
                dieDeriving("row\(row)", launch: "\(launch)")
            }
        }
        let next = recover(launch: "last")
        let quarantined = store.string(forKey: LaunchPassRowQuarantine.quarantineKey(forPassKey: passKey))?
            .split(separator: "\n") ?? []
        XCTAssertEqual(quarantined.count, limit)
        XCTAssertTrue(next.isQuarantined("row\(limit + 9)"))
        XCTAssertFalse(next.isQuarantined("row0"), "The oldest quarantine gives way")
    }
}
