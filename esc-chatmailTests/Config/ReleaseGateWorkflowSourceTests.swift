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
        XCTAssertTrue(job.contains("contents: write"))
        // Exactly one push, and it is this line: no flag, no `+` refspec, no other ref.
        let pushLines = job.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.contains("git push") }
        XCTAssertEqual(pushLines, ["git push origin \"${GITHUB_SHA}:refs/heads/testflight\""])
        for forbidden in ["--force", "--mirror", "+refs/", "+${"] {
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
            // A job key or a comment at the jobs' own indent (the next job's preamble), or
            // anything at the top level, ends the block.
            let isAtJobIndent = line.hasPrefix("  ") && !line.hasPrefix("   ")
            let isJobKeyOrPreamble = isAtJobIndent
                && (line.hasSuffix(":") || line.trimmingCharacters(in: .whitespaces).hasPrefix("#"))
            if isJobKeyOrPreamble || (!line.isEmpty && !line.hasPrefix(" ") && !line.hasPrefix("#")) {
                end = index
                break
            }
        }
        return lines[start..<end].joined(separator: "\n")
    }
}
