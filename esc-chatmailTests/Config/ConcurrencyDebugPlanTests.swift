import XCTest
@testable import esc_chatmail

/// `ConcurrencyDebug.xctestplan` runs the suites measured clean under Core Data's
/// `-com.apple.CoreData.ConcurrencyDebug 1`, which traps on a context touched off its queue
/// (architecture review 2026-11, testing-ci-release#4). The default plan cannot carry the flag:
/// `TestCoreDataStack.viewContext` is private-queue and about fifty suites touch it off-queue
/// by design, so a whole-plan flag would crash once per test. This plan is the ratchet
/// instead: a suite is added once it has been run under the flag with no crash
/// (CLAUDE.md, Testing), and from then on an off-queue access in the code it covers fails
/// CI as a crashed test instead of shipping as a rare crash or a lost save.
///
/// The canary runs in the plan and asserts the flag reached the host; everything else about
/// the plan, the switch and the CI step is pinned from source, because no test runs them.
final class ConcurrencyDebugPlanTests: XCTestCase {
    static let planEnvironmentKey = "ESC_CHATMAIL_CONCURRENCY_DEBUG_PLAN"
    static let flagArgument = "-com.apple.CoreData.ConcurrencyDebug"

    /// Under the plan, the host must have the flag, or every suite in the plan passes for
    /// nothing. Skipped under any other plan: the flag is the plan's alone.
    // Revert-check: fails if the plan loses its command-line arguments (the environment
    // entry would still select this test, and the defaults would read 0).
    func testHost_underTheConcurrencyDebugPlan_hasCoreDatasConcurrencyDebugFlag() throws {
        let environment = ProcessInfo.processInfo.environment
        try XCTSkipUnless(environment[Self.planEnvironmentKey] == "1", "not the ConcurrencyDebug plan")

        XCTAssertTrue(ProcessInfo.processInfo.arguments.contains(Self.flagArgument), "\(ProcessInfo.processInfo.arguments)")
        XCTAssertEqual(UserDefaults.standard.integer(forKey: "com.apple.CoreData.ConcurrencyDebug"), 1)
    }

    // Revert-check: fails if the plan drops the flag or its environment marker, claims to be
    // the Mac plan (whose marker only Mac.xctestplan may set), lists no suites, or lists a
    // suite the default plan skips (the scale and performance suites seed a 120k store).
    func testPlan_passesTheFlag_marksItself_andSelectsMeasuredSuites() throws {
        let plan = try planJSON("ConcurrencyDebug.xctestplan")
        let defaults = try XCTUnwrap(plan["defaultOptions"] as? [String: Any])

        let arguments = (defaults["commandLineArgumentEntries"] as? [[String: Any]] ?? []).compactMap { $0["argument"] as? String }
        XCTAssertEqual(arguments, [Self.flagArgument, "1"])

        let environment = Dictionary(
            uniqueKeysWithValues: (defaults["environmentVariableEntries"] as? [[String: Any]] ?? [])
                .compactMap { entry -> (String, String)? in
                    guard let key = entry["key"] as? String, let value = entry["value"] as? String else { return nil }
                    return (key, value)
                }
        )
        XCTAssertEqual(environment[Self.planEnvironmentKey], "1")
        XCTAssertNil(environment[MacUnitTestHostPolicy.macTestPlanEnvironmentKey])

        let targets = try XCTUnwrap(plan["testTargets"] as? [[String: Any]])
        XCTAssertEqual(targets.count, 1)
        let selected = try XCTUnwrap(targets[0]["selectedTests"] as? [String])
        XCTAssertGreaterThan(selected.count, 50)
        XCTAssertEqual(selected, selected.sorted(), "keep the list sorted, so a diff shows one added suite")
        XCTAssertEqual(Set(selected).count, selected.count)
        XCTAssertTrue(selected.contains("ConcurrencyDebugPlanTests"), "the canary must run in the plan")
        for skipped in ["PerformanceRegressionTests", "ScaleHubFaultTests", "ScaleQueryPlanTests"] {
            XCTAssertFalse(selected.contains(skipped), skipped)
        }
    }

    // Revert-check: fails if --concurrency-debug stops picking the plan, runs in parallel
    // (clones blur which host crashed), is accepted on a Mac destination or beside
    // --performance, or if codex-test.sh's usage stops naming it.
    func testRunTests_concurrencyDebugSwitch_picksThePlan_seriallyOnTheIOSSimulatorOnly() throws {
        let script = try repositorySource("Scripts/run-tests.sh")

        XCTAssertTrue(script.contains("--concurrency-debug)"))
        XCTAssertTrue(script.contains(
            "if [[ \"${IS_MAC_DESTINATION}\" == \"true\" || \"${RUN_PERFORMANCE_TESTS}\" == \"true\" ]]; then"
        ))
        XCTAssertTrue(script.contains("ARGS+=(\"-testPlan\" \"ConcurrencyDebug\" \"-parallel-testing-enabled\" \"NO\")"))
        XCTAssertTrue(try repositorySource("Scripts/codex-test.sh").contains("--concurrency-debug"))
    }

    // Revert-check: fails if CI stops running the plan after the default plan, makes the
    // step advisory (`continue-on-error` anywhere in the step, which would let ship-gate
    // advance a commit whose plan crashed), or if the scheme stops referencing the plan
    // (Xcode would then not offer it).
    func testCI_runsThePlanAfterTheDefaultPlan_blocking_andTheSchemeReferencesIt() throws {
        let workflow = try repositorySource(".github/workflows/ci.yml")
        let defaultPlan = try XCTUnwrap(workflow.range(of: "bash Scripts/run-tests.sh \\\n            -resultBundlePath TestResults.xcresult"))
        let stepName = try XCTUnwrap(workflow.range(of: "      - name: Run tests (ConcurrencyDebug test plan)\n"))
        XCTAssertLessThan(defaultPlan.lowerBound, stepName.lowerBound)
        // The step is every line from its name to the next step's.
        let rest = String(workflow[stepName.upperBound...])
        let step = String(rest[..<(rest.range(of: "      - name: ")?.lowerBound ?? rest.endIndex)])
        XCTAssertTrue(step.contains("bash Scripts/run-tests.sh --concurrency-debug \\"), step)
        XCTAssertFalse(step.contains("continue-on-error"), step)

        let scheme = try repositorySource("esc-chatmail.xcodeproj/xcshareddata/xcschemes/esc-chatmail.xcscheme")
        XCTAssertTrue(scheme.contains("reference = \"container:ConcurrencyDebug.xctestplan\""))
    }

    private func planJSON(_ name: String) throws -> [String: Any] {
        let data = Data(try repositorySource(name).utf8)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any], name)
    }
}
