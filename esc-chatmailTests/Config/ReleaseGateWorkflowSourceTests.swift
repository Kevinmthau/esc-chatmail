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
        let condition = job.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix("if:") }
        XCTAssertEqual(condition, ["if: github.event_name == 'push' && github.ref == 'refs/heads/main'"])
        XCTAssertTrue(job.contains("contents: write"))
        // Every push is this refspec: no flag, no `+` refspec, no other ref.
        let pushLines = job.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.contains("git push") }
        XCTAssertEqual(pushLines, [
            "if git push origin \"${GITHUB_SHA}:refs/heads/testflight\"; then",
            "&& git push origin \"${GITHUB_SHA}:refs/heads/testflight\"; then"
        ])
        XCTAssertFalse(job.contains("--force"))
        XCTAssertFalse(job.contains("--mirror"))
    }

    /// Only `ship-gate` may write, and only contents.
    // Revert-check: fails if the top-level `permissions: contents: read` is removed, or
    // another job (or the workflow) is given any write permission.
    func testWorkflow_isReadOnlyByDefault() throws {
        let workflow = try repositorySource(".github/workflows/ci.yml")
        XCTAssertTrue(workflow.contains("permissions:\n  contents: read\n"))
        XCTAssertEqual(workflow.components(separatedBy: ": write").count - 1, 1)
        XCTAssertFalse(workflow.contains("write-all"))
        XCTAssertTrue(try jobBlock(named: "ship-gate").contains("contents: write"))
    }

    // Revert-check: fails if pushes to main share one concurrency group again (a re-run of
    // an older main run would cancel the newest one, which then never ships), or if the
    // ship-gate loses its no-op for a commit `testflight` already contains (an older run
    // finishing last would fail on every pair of close merges).
    func testMainRunsAreNotCancelled_andAnOlderRunFinishingLastIsANoOp() throws {
        let workflow = try repositorySource(".github/workflows/ci.yml")
        XCTAssertTrue(workflow.contains(
            "group: ci-${{ github.ref }}-${{ github.event_name == 'push' && github.sha || 'latest' }}"
        ))
        let job = try jobBlock(named: "ship-gate")
        XCTAssertTrue(job.contains("git merge-base --is-ancestor \"${GITHUB_SHA}\" refs/remotes/origin/testflight"))
        // Checked before the push (the older run finishing last) and again after a
        // rejected push (a newer run's push landing in between).
        let push = try XCTUnwrap(job.range(of: "git push origin"))
        let checkBefore = try XCTUnwrap(job.range(of: "if already_shipped; then"))
        XCTAssertLessThan(checkBefore.lowerBound, push.lowerBound)
        XCTAssertNotNil(job.range(of: "if already_shipped; then", range: push.upperBound..<job.endIndex))
        // The check reads testflight as it is now: without the forced fetch it reads the
        // ref the checkout made at job start, and the check after a rejected push cannot
        // see the newer run's push.
        XCTAssertTrue(job.contains(
            "git fetch --quiet origin +refs/heads/testflight:refs/remotes/origin/testflight"
        ))
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

    /// The scale harness runs in CI after the default plan, on its own (architecture review
    /// 2026-11, testing-ci-release#5): both scale suites under the Performance plan, never
    /// PerformanceRegressionTests, and the default plan still skips all three.
    // Revert-check: fails if the step is removed, loses either scale suite, gains
    // PerformanceRegressionTests, if `continue-on-error` leaves the scale step (on the job it
    // would let ship-gate advance a commit whose default plan failed; gone, the step blocks
    // before it has passed on this runner), or if esc-chatmail.xctestplan stops skipping the
    // scale suites (which would run them inside the default plan, where the process-wide
    // plan recorder and the half-minute seed make them flaky).
    func testTestJob_runsTheScaleHarnessAfterTheDefaultPlan_advisory_andTheDefaultPlanStillSkipsIt() throws {
        let job = try jobBlock(named: "test")

        let defaultPlan = try XCTUnwrap(job.range(of: "bash Scripts/run-tests.sh \\\n            -resultBundlePath TestResults.xcresult"))
        let scale = try XCTUnwrap(job.range(of: "bash Scripts/run-tests.sh --performance \\"))
        XCTAssertLessThan(defaultPlan.lowerBound, scale.lowerBound)
        let scaleStep = String(job[scale.lowerBound...])
        XCTAssertTrue(scaleStep.contains("-parallel-testing-enabled NO"))
        // `continue-on-error` once in the job, inside the scale step: between its name and
        // its run, never on the job or another step.
        let stepName = try XCTUnwrap(job.range(of: "      - name: Run the scale harness (Performance test plan, scale suites only)\n"))
        let stepHead = String(job[stepName.upperBound..<scale.lowerBound])
        XCTAssertTrue(stepHead.contains("        continue-on-error: true\n"), stepHead)
        XCTAssertEqual(job.components(separatedBy: "continue-on-error").count - 1, 1)
        // Exactly the two scale suites: every -only-testing in the job, in order.
        let onlyTesting = job.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix("-only-testing ") }
        XCTAssertEqual(onlyTesting, [
            "-only-testing esc-chatmailTests/ScaleQueryPlanTests \\",
            "-only-testing esc-chatmailTests/ScaleHubFaultTests \\"
        ])

        let plan = try repositorySource("esc-chatmail.xctestplan")
        let skipped = try XCTUnwrap(plan.range(of: "\"skippedTests\""))
        let skippedBlock = String(plan[skipped.lowerBound...])
        for suite in ["PerformanceRegressionTests", "ScaleHubFaultTests", "ScaleQueryPlanTests"] {
            XCTAssertTrue(skippedBlock.contains("\"\(suite)\""), suite)
        }
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
