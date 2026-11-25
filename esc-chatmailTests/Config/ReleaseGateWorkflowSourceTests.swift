import XCTest

/// The gate between a merge and TestFlight lives in `.github/workflows/ci.yml`, which no
/// test runs, so its shape is pinned from source (architecture review 2026-11,
/// testing-ci-release#1 and #2).
final class ReleaseGateWorkflowSourceTests: XCTestCase {
    // Revert-check: fails if `ship-gate` stops needing any build or test job, stops being
    // limited to a push to main, or pushes with --force or a `+` refspec (which would let
    // a re-run of an older commit move the shipped branch back).
    func testShipGate_advancesTestflightOnlyAfterEveryJobOnAPushToMain_neverByForce() throws {
        let job = try jobBlock(named: "ship-gate")

        XCTAssertTrue(job.contains("needs: [test, build-macos, build-release-ios]"))
        XCTAssertTrue(job.contains("if: github.event_name == 'push' && github.ref == 'refs/heads/main'"))
        XCTAssertTrue(job.contains("git push origin \"${GITHUB_SHA}:refs/heads/testflight\""))
        XCTAssertTrue(job.contains("contents: write"))
        for forbidden in ["--force", "push -f", "push origin -f", "\"+", " +$", "+refs/"] {
            XCTAssertFalse(job.contains(forbidden), forbidden)
        }
    }

    /// Only `ship-gate` may write.
    func testWorkflow_isReadOnlyByDefault() throws {
        let workflow = try repositorySource(".github/workflows/ci.yml")
        XCTAssertTrue(workflow.contains("permissions:\n  contents: read\n"))
        XCTAssertEqual(workflow.components(separatedBy: "contents: write").count - 1, 1)
    }

    // Revert-check: fails if the Release job stops building Release or stops checking the
    // built Info.plist.
    func testReleaseJob_buildsReleaseAndChecksTheBuiltInfoPlist() throws {
        let job = try jobBlock(named: "build-release-ios")

        XCTAssertTrue(job.contains("CONFIGURATION=Release"))
        XCTAssertTrue(job.contains("bash Scripts/check-built-info-plist.sh"))
        XCTAssertTrue(job.contains("Release-iphonesimulator/esc-chatmail.app"))
    }

    // Revert-check: fails if codex-build.sh goes back to a hard-coded `-configuration Debug`.
    func testCodexBuild_takesItsConfigurationFromTheEnvironment() throws {
        let script = try repositorySource("Scripts/codex-build.sh")

        XCTAssertTrue(script.contains("CONFIGURATION=\"${CONFIGURATION:-Debug}\""))
        XCTAssertTrue(script.contains("-configuration \"${CONFIGURATION}\""))
        XCTAssertFalse(script.contains("-configuration Debug"))
    }

    /// The lines of one job, from its key to the next job's.
    private func jobBlock(named name: String) throws -> String {
        let workflow = try repositorySource(".github/workflows/ci.yml")
        let lines = workflow.components(separatedBy: "\n")
        let start = try XCTUnwrap(lines.firstIndex(of: "  \(name):"), "no job \(name)")
        var end = lines.count
        for index in (start + 1)..<lines.count {
            let line = lines[index]
            let isJobKey = line.hasPrefix("  ") && !line.hasPrefix("   ") && line.hasSuffix(":")
            if isJobKey || (!line.isEmpty && !line.hasPrefix(" ") && !line.hasPrefix("#")) {
                end = index
                break
            }
        }
        return lines[start..<end].joined(separator: "\n")
    }
}
