import XCTest
@testable import esc_chatmail

/// CI launches the Release build on an erased simulator (`Scripts/launch-smoke.sh`;
/// architecture review 2026-11, testing-ci-release#2, part 2). No test runs the script, so
/// what it checks, what it greps for and where CI runs it are pinned from source.
final class LaunchSmokeSourceTests: XCTestCase {
    // Revert-check: fails if the smoke stops erasing the device, stops checking the
    // process, the crash reports, the launch log or the store, or loses `set -e`.
    func testLaunchSmoke_erasesInstallsLaunches_andChecksAllFourWitnesses() throws {
        let script = try repositorySource("Scripts/launch-smoke.sh")

        XCTAssertTrue(script.contains("set -euo pipefail"))
        for step in [
            "xcrun simctl erase \"${UDID}\"",
            "xcrun simctl bootstatus \"${UDID}\" -b",
            "xcrun simctl install \"${UDID}\" \"${APP}\"",
            "xcrun simctl launch \"${UDID}\" \"${BUNDLE_ID}\"",
            "kill -0 \"${PID}\"",
            "-newer \"${MARKER}\"",
            "log show --style compact --start \"${START}\"",
            "Library/Application Support/ESCChatmail.sqlite"
        ] {
            XCTAssertTrue(script.contains(step), step)
        }
        // A failure is counted, never swallowed, and the exit status says so.
        XCTAssertTrue(script.contains("if [[ ${failures} -gt 0 ]]; then"))
    }

    /// With no second argument (how CI calls it) the device comes out of the destination
    /// line `default-simulator-destination.py` prints, and is checked for a UDID's shape
    /// before anything is erased. The first version asked the picker for `--udid`, a mode
    /// it did not have on this branch, so `UDID` held the whole destination line and
    /// `simctl erase` would have aborted the Release job, and with it `ship-gate`
    /// (Codex review of PR 501). The local run had passed a UDID by hand.
    // Revert-check: fails if the script asks the picker for a mode, stops parsing the
    // `id=` tail, or erases before checking the UDID's shape.
    func testLaunchSmoke_withNoDevice_readsTheUDIDOutOfThePickersDestinationLine_andChecksItsShape() throws {
        let script = try repositorySource("Scripts/launch-smoke.sh")

        XCTAssertTrue(script.contains("DESTINATION_LINE=\"$(python3 \"$(dirname \"${BASH_SOURCE[0]}\")/default-simulator-destination.py\")\""))
        XCTAssertTrue(script.contains("UDID=\"${DESTINATION_LINE##*id=}\""))
        XCTAssertFalse(script.contains("default-simulator-destination.py\" --"), "the picker takes no arguments here")
        let check = try XCTUnwrap(script.range(of: "if ! [[ \"${UDID}\" =~ ^[0-9A-Fa-f]{8}(-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12}$ ]]; then"))
        let erase = try XCTUnwrap(script.range(of: "xcrun simctl erase \"${UDID}\""))
        XCTAssertLessThan(check.lowerBound, erase.lowerBound)
        // The picker on this branch prints the destination line and nothing else.
        let picker = try repositorySource("Scripts/default-simulator-destination.py")
        XCTAssertTrue(picker.contains("print(f\"platform=iOS Simulator,id={device_id}\")"))
    }

    /// The script greps for the line `LaunchRootScreenRecord` writes for the sign-in root.
    // Revert-check: fails if either side spells the line differently.
    func testLaunchSmoke_grepsForTheLineTheAppRecordsForTheSignInRoot() throws {
        let script = try repositorySource("Scripts/launch-smoke.sh")
        let expected = LaunchRootScreenRecord.messagePrefix + LaunchRootScreen.signIn.accessibilityIdentifier

        XCTAssertTrue(script.contains("EXPECTED_LINE=\"\(expected)\""), expected)
        XCTAssertTrue(script.contains("AND category == \\\"\(LaunchRootScreenRecord.category)\\\""))
    }

    /// CI runs the smoke on the Release build, after the Info.plist check, and nowhere else:
    /// not in a test plan and not from run-tests.sh, which would erase the device a test
    /// run is using.
    // Revert-check: fails if the Release job stops launching the build it checked, or if
    // the smoke is wired into run-tests.sh, codex-test.sh or a test plan.
    func testReleaseJob_launchesTheBuildItChecked_andNothingElseRunsTheSmoke() throws {
        let workflow = try repositorySource(".github/workflows/ci.yml")
        let plist = try XCTUnwrap(workflow.range(of: "bash Scripts/check-built-info-plist.sh"))
        let smoke = try XCTUnwrap(workflow.range(of: "bash Scripts/launch-smoke.sh"))
        XCTAssertLessThan(plist.lowerBound, smoke.lowerBound)
        XCTAssertTrue(String(workflow[smoke.lowerBound...]).contains("Release-iphonesimulator/esc-chatmail.app"))

        for path in ["Scripts/run-tests.sh", "Scripts/codex-test.sh", "Scripts/codex-build.sh"] {
            XCTAssertFalse(try repositorySource(path).contains("launch-smoke"), path)
        }
        let plans = try FileManager.default.contentsOfDirectory(atPath: Self.repoRoot.path)
            .filter { $0.hasSuffix(".xctestplan") }
        XCTAssertFalse(plans.isEmpty)
        for plan in plans {
            XCTAssertFalse(try repositorySource(plan).contains("launch-smoke"), plan)
        }
    }

    /// This file is esc-chatmailTests/Config/, so the repo root is three directories up.
    private static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
}
