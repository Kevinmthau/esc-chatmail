import XCTest
@testable import esc_chatmail

/// Pins the guard that keeps a Mac test host from running anything but `Mac.xctestplan` in the
/// App Sandbox (`MacUnitTestHostPolicy`, applied by `MacUnitTestHostGuard`).
///
/// The policy is pure, so its tests run on iOS. The guard and its call site compile only for
/// macOS and end in `exit`, so on iOS they are pinned from the source text and the test plan
/// files, the way `SandboxTripwireTests` pins the tripwire's call sites.
final class MacUnitTestHostPolicyTests: XCTestCase {
    private let sandbox = [SandboxTripwirePolicy.containerIdentifierEnvironmentKey: "com.esc.inboxchat"]
    private let macTestPlan = [
        MacUnitTestHostPolicy.macTestPlanEnvironmentKey: MacUnitTestHostPolicy.macTestPlanEnvironmentValue
    ]

    // MARK: - Decision

    /// Revert-check: returning a refusal for every environment from
    /// `MacUnitTestHostPolicy.verdict(environment:)` fails this, and with it every Mac test run.
    func testVerdict_sandboxedHostStartedByTheMacTestPlan_isPermitted() {
        let environment = sandbox.merging(macTestPlan) { current, _ in current }

        XCTAssertEqual(MacUnitTestHostPolicy.verdict(environment: environment), .permitted)
    }

    /// The case behind "never launch an unsandboxed Mac build": the plan's marker must not be
    /// enough on its own, because `xcodebuild test -testPlan Mac CODE_SIGNING_ALLOWED=NO` sets it
    /// in a host with no sandbox.
    ///
    /// Revert-check: removing the `SandboxTripwirePolicy` guard from
    /// `MacUnitTestHostPolicy.verdict(environment:)` fails this.
    func testVerdict_macTestPlanOutsideTheSandbox_isRefused() {
        let blankContainer = [SandboxTripwirePolicy.containerIdentifierEnvironmentKey: "  "]

        XCTAssertEqual(MacUnitTestHostPolicy.verdict(environment: macTestPlan), .refusedOutsideAppSandbox)
        XCTAssertEqual(
            MacUnitTestHostPolicy.verdict(environment: macTestPlan.merging(blankContainer) { current, _ in current }),
            .refusedOutsideAppSandbox
        )
        XCTAssertEqual(MacUnitTestHostPolicy.verdict(environment: [:]), .refusedOutsideAppSandbox)
    }

    /// Cmd-U in Xcode with My Mac selected runs the default plan in a signed, sandboxed host.
    /// Its suites are written for a simulator's container, not the app's real one.
    ///
    /// Revert-check: removing the `macTestPlanEnvironmentKey` guard from
    /// `MacUnitTestHostPolicy.verdict(environment:)` fails this.
    func testVerdict_sandboxedHostStartedByAnotherTestPlan_isRefused() {
        let wrongValue = [MacUnitTestHostPolicy.macTestPlanEnvironmentKey: "0"]
        let emptyValue = [MacUnitTestHostPolicy.macTestPlanEnvironmentKey: ""]

        XCTAssertEqual(MacUnitTestHostPolicy.verdict(environment: sandbox), .refusedOutsideMacTestPlan)
        XCTAssertEqual(
            MacUnitTestHostPolicy.verdict(environment: sandbox.merging(wrongValue) { current, _ in current }),
            .refusedOutsideMacTestPlan
        )
        XCTAssertEqual(
            MacUnitTestHostPolicy.verdict(environment: sandbox.merging(emptyValue) { current, _ in current }),
            .refusedOutsideMacTestPlan
        )
    }

    // MARK: - Test plans

    /// The policy and `Mac.xctestplan` must agree on the marker, or every Mac test run is
    /// refused.
    ///
    /// Revert-check: removing `environmentVariableEntries` from `Mac.xctestplan`, or renaming
    /// `MacUnitTestHostPolicy.macTestPlanEnvironmentKey`, fails this.
    func testMacTestPlan_setsTheMarkerThePolicyRequires() throws {
        XCTAssertEqual(
            try environmentEntries(ofTestPlan: "Mac.xctestplan")[MacUnitTestHostPolicy.macTestPlanEnvironmentKey],
            MacUnitTestHostPolicy.macTestPlanEnvironmentValue
        )
    }

    /// A plan that set the marker would run its suites in the app's real container. Every plan
    /// in the repo root is checked, so a new one is covered without being listed here.
    ///
    /// Revert-check: adding the marker to `esc-chatmail.xctestplan` fails this.
    func testEveryOtherTestPlan_doesNotSetTheMarker() throws {
        let planNames = try FileManager.default.contentsOfDirectory(atPath: Self.repoRoot.path)
            .filter { $0.hasSuffix(".xctestplan") && $0 != "Mac.xctestplan" }
        XCTAssertTrue(planNames.contains("esc-chatmail.xctestplan"), "Scan root must be the repo root: \(planNames)")

        for planName in planNames {
            XCTAssertNil(
                try environmentEntries(ofTestPlan: planName)[MacUnitTestHostPolicy.macTestPlanEnvironmentKey],
                "\(planName) must not claim to be the Mac test plan"
            )
        }
    }

    // MARK: - Call site

    /// The guard has to run before the app touches the disk, so it is the first statement of the
    /// app's `init`, in a macOS branch with no `#else`.
    ///
    /// Revert-check: removing `MacUnitTestHostGuard.exitUnlessPermitted()` from
    /// `esc_chatmailApp.init`, or moving it below another statement, fails this.
    ///
    /// HONEST SCOPE: this reads source text. It proves the call is present, first and compiled
    /// for macOS; it cannot prove the macOS branch runs.
    func testAppInit_callsTheGuardFirst_inAMacOSBranch() throws {
        let source = try String(
            contentsOf: Self.repoRoot.appendingPathComponent("esc-chatmail/App/esc_chatmailApp.swift"),
            encoding: .utf8
        )
        let lines = source.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
        let initIndex = try XCTUnwrap(lines.firstIndex(of: "init() {"), "esc_chatmailApp must declare init()")
        let statements = lines[(initIndex + 1)...].filter { !$0.isEmpty && !$0.hasPrefix("//") }

        XCTAssertEqual(
            Array(statements.prefix(3)),
            ["#if os(macOS)", "MacUnitTestHostGuard.exitUnlessPermitted()", "#endif"]
        )
        XCTAssertEqual(
            lines.filter { $0.contains("MacUnitTestHostGuard.exitUnlessPermitted(") }.count,
            1,
            "The guard is applied once, at the top of init"
        )
    }

    #if os(macOS)
    /// A Mac test run that gets this far was permitted, so this cannot fail on its own. It
    /// records what a permitted host looks like: the run is sandboxed, and `Mac.xctestplan`'s
    /// environment entry reaches the host before its `init`.
    ///
    /// HONEST SCOPE: no revert makes this fail. A host that the policy refuses exits before any
    /// test runs. That was checked by running this suite with the entry removed from
    /// `Mac.xctestplan`: the host exited and no test ran.
    func testRealProcessEnvironment_inAMacTestHost_isPermitted() {
        XCTAssertEqual(
            MacUnitTestHostPolicy.verdict(environment: ProcessInfo.processInfo.environment),
            .permitted
        )
    }
    #endif

    // MARK: - Helpers

    /// This file is esc-chatmailTests/Security/, so the repo root is three directories up.
    private static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    /// The environment a test plan gives its test host: its default options' entries, overlaid
    /// by each configuration's.
    private func environmentEntries(ofTestPlan name: String) throws -> [String: String] {
        let data = try Data(contentsOf: Self.repoRoot.appendingPathComponent(name))
        let plan = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any], name)
        var optionSets: [[String: Any]] = []
        if let defaultOptions = plan["defaultOptions"] as? [String: Any] {
            optionSets.append(defaultOptions)
        }
        for configuration in plan["configurations"] as? [[String: Any]] ?? [] {
            if let options = configuration["options"] as? [String: Any] {
                optionSets.append(options)
            }
        }

        var environment: [String: String] = [:]
        for options in optionSets {
            for entry in options["environmentVariableEntries"] as? [[String: Any]] ?? [] {
                if let key = entry["key"] as? String, let value = entry["value"] as? String {
                    environment[key] = value
                }
            }
        }
        return environment
    }
}
