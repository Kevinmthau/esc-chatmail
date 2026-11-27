import XCTest

/// CI runs `Mac.xctestplan` in a Mac test host it signs ad hoc (architecture review 2026-11,
/// mac-platform#1, testing-ci-release#3). The arrangement is a workflow step, a script switch,
/// an xcconfig and an entitlements file, none of which a test runs, so its shape is pinned from
/// source: the host CI launches is sandboxed and is nobody's installed app, and the two
/// sandbox checks in front of it (`verify-mac-test-host.sh`, `MacUnitTestHostGuard`) are the
/// ones every other Mac run passes through, unchanged.
final class MacCITestHostSourceTests: XCTestCase {
    // Revert-check: fails if the Mac job goes back to the unsigned compile-only build
    // (`codex-build.sh --for-testing CODE_SIGNING_ALLOWED=NO`), calls xcodebuild itself
    // instead of run-tests.sh (which would skip verify-mac-test-host.sh), or drops
    // --ci-mac-host (a team signature CI cannot make).
    func testBuildMacosJob_runsTheMacPlanThroughRunTestsWithTheCIHost_neverUnsignedOrBare() throws {
        let job = try jobBlock(named: "build-macos")

        XCTAssertTrue(job.contains("DESTINATION='platform=macOS' bash Scripts/run-tests.sh --ci-mac-host \\"))
        XCTAssertFalse(job.contains("CODE_SIGNING_ALLOWED=NO"))
        XCTAssertFalse(job.contains("codex-build.sh"))
        XCTAssertFalse(job.contains("xcodebuild test"))
        XCTAssertFalse(job.contains("test-without-building"))
        XCTAssertFalse(job.contains("continue-on-error"))
    }

    // Revert-check: fails if --ci-mac-host stops being refused for an iOS destination, stops
    // passing the CI xcconfig, or skips any suite but KeychainServiceTests (a wider skip would
    // hide a Mac regression from the one run that sees it).
    func testRunTests_ciMacHost_isMacOnly_signsWithTheCIXcconfig_andSkipsOnlyKeychainServiceTests() throws {
        let script = try repositorySource("Scripts/run-tests.sh")

        XCTAssertTrue(script.contains(
            "if [[ \"${USE_CI_MAC_HOST}\" == \"true\" && \"${IS_MAC_DESTINATION}\" != \"true\" ]]; then"
        ))
        XCTAssertTrue(script.contains("ARGS+=(\"-xcconfig\" \"Scripts/CI-MacTestHost.xcconfig\")"))
        let skips = script.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.contains("-skip-testing") }
        XCTAssertEqual(skips, ["ARGS+=(\"-skip-testing:esc-chatmailTests/KeychainServiceTests\")"])
        // The xcconfig reaches the host lookup too, so the host checked is the host launched.
        XCTAssertTrue(script.contains("-derivedDataPath | -configuration | -xcconfig |"))
        // The sandbox check still stands in front of every Mac run, the CI one included.
        let verify = try XCTUnwrap(script.range(of: "verify-mac-test-host.sh\" \"${TEST_HOST%/Contents/MacOS/*}\""))
        let run = try XCTUnwrap(script.range(of: "exec xcodebuild test-without-building"))
        XCTAssertLessThan(verify.lowerBound, run.lowerBound)
    }

    // Revert-check: fails if the CI xcconfig signs with a team or a profile, turns the
    // sandbox off, names an entitlements file other than the CI one, or drops the .ci suffix
    // (the host would then share the installed MushMail's container on a developer Mac).
    func testCIMacHostXcconfig_signsAdHocWithoutATeam_keepsTheSandbox_andSuffixesTheBundleID() throws {
        // Outside esc-chatmail/, the filesystem-synchronized group: a file there that
        // project.pbxproj's membershipExceptions do not name is copied into every product, and
        // this one would have shipped inside MushMail.app's Resources (PR 498 review).
        XCTAssertThrowsError(try repositorySource("esc-chatmail/Configuration/CI-MacTestHost.xcconfig"))
        let xcconfig = try repositorySource("Scripts/CI-MacTestHost.xcconfig")
        let settings = xcconfig.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("//") }

        XCTAssertEqual(settings, [
            "CODE_SIGN_STYLE = Manual",
            "CODE_SIGN_IDENTITY = -",
            "DEVELOPMENT_TEAM =",
            "PROVISIONING_PROFILE_SPECIFIER =",
            "ESC_CI_MAC_HOST_ENTITLEMENTS_MushMail = esc-chatmail/Resources/esc_chatmail-macOS-CI.entitlements",
            "CODE_SIGN_ENTITLEMENTS[sdk=macosx*] = $(ESC_CI_MAC_HOST_ENTITLEMENTS_$(PRODUCT_NAME))",
            "PRODUCT_BUNDLE_IDENTIFIER = $(inherited).ci"
        ])
    }

    /// The CI entitlements are the team's without `keychain-access-groups`, which needs a
    /// provisioning profile, and with the App Sandbox named outright.
    // Revert-check: fails if the CI entitlements lose the sandbox or gain the keychain group.
    func testCIMacHostEntitlements_keepTheSandbox_andHaveNoKeychainAccessGroups() throws {
        let ci = try entitlements("esc-chatmail/Resources/esc_chatmail-macOS-CI.entitlements")
        let team = try entitlements("esc-chatmail/Resources/esc_chatmail-macOS.entitlements")

        XCTAssertEqual(ci["com.apple.security.app-sandbox"] as? Bool, true)
        XCTAssertNil(ci["keychain-access-groups"])
        XCTAssertNotNil(team["keychain-access-groups"], "the team's file is what CI's leaves out")
        XCTAssertEqual(Set(ci.keys), ["com.apple.security.app-sandbox"])
    }

    /// The sandbox check the CI host passes through is the one every Mac run passes through.
    // Revert-check: fails if verify-mac-test-host.sh stops verifying the signature or stops
    // requiring the App Sandbox entitlement, or if a CI-only branch is added to it.
    func testVerifyMacTestHost_isAsStrictForTheCIHostAsForAnyOther() throws {
        let script = try repositorySource("Scripts/verify-mac-test-host.sh")

        XCTAssertTrue(script.contains("if ! codesign --verify \"${HOST_APP}\" 2>/dev/null; then"))
        XCTAssertTrue(script.contains("sys.exit(0 if entitlements.get(\"com.apple.security.app-sandbox\") is True else 1)"))
        XCTAssertFalse(script.contains("CI"))
        XCTAssertFalse(script.contains("ci-mac-host"))
    }

    /// The lines of one job, from its key to the next job's (as `ReleaseGateWorkflowSourceTests`).
    private func jobBlock(named name: String) throws -> String {
        let workflow = try repositorySource(".github/workflows/ci.yml")
        let lines = workflow.components(separatedBy: "\n")
        let start = try XCTUnwrap(lines.firstIndex(of: "  \(name):"), "no job \(name)")
        var end = lines.count
        for index in (start + 1)..<lines.count {
            let line = lines[index]
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

    private func entitlements(_ path: String) throws -> [String: Any] {
        let data = Data(try repositorySource(path).utf8)
        return try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any], path)
    }
}
