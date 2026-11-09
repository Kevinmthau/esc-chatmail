import XCTest
@testable import esc_chatmail

/// Pins the macOS sandbox tripwire's decision (docs/mac-app-plan.md, PR C).
/// The policy is pure, so these run on iOS even though only macOS call sites
/// consult it.
final class SandboxTripwirePolicyTests: XCTestCase {
    // Revert-check: fails if SandboxTripwirePolicy.destructiveCleanupVerdict(environment:)
    // stops permitting a process whose environment names its App Sandbox
    // container. A correctly sandboxed Mac build would then never finish
    // sign-out or fresh-install cleanup.
    func testDestructiveCleanupVerdict_containerIdentifierPresent_permitsCleanup() {
        let environment = [
            SandboxTripwirePolicy.containerIdentifierEnvironmentKey: "com.esc.inboxchat",
            "HOME": "/Users/someone/Library/Containers/com.esc.inboxchat/Data"
        ]

        XCTAssertEqual(
            SandboxTripwirePolicy.destructiveCleanupVerdict(environment: environment),
            .permitted
        )
    }

    // Revert-check: fails if destructiveCleanupVerdict(environment:) permits a
    // process without a container identifier: an unsandboxed Mac build, whose
    // Documents and Application Support folders are the user's own. A HOME
    // that merely looks like a container path must not count as evidence.
    func testDestructiveCleanupVerdict_containerIdentifierMissing_refusesCleanup() {
        let environments: [[String: String]] = [
            [:],
            ["HOME": "/Users/someone", "PATH": "/usr/bin:/bin"],
            ["HOME": "/Users/someone/Library/Containers/com.esc.inboxchat/Data"]
        ]

        for environment in environments {
            XCTAssertEqual(
                SandboxTripwirePolicy.destructiveCleanupVerdict(environment: environment),
                .refusedOutsideAppSandbox,
                "environment: \(environment)"
            )
        }
    }

    // Revert-check: fails if destructiveCleanupVerdict(environment:) treats the
    // key's presence alone as proof of a sandbox, i.e. drops the blank-value
    // check. When the evidence is unclear, the files must stay.
    func testDestructiveCleanupVerdict_containerIdentifierBlank_refusesCleanup() {
        for blank in ["", " ", "\n\t"] {
            let environment = [SandboxTripwirePolicy.containerIdentifierEnvironmentKey: blank]

            XCTAssertEqual(
                SandboxTripwirePolicy.destructiveCleanupVerdict(environment: environment),
                .refusedOutsideAppSandbox,
                "identifier: \(blank.debugDescription)"
            )
        }
    }

    // Revert-check: fails if SandboxTripwirePolicy.containerIdentifierEnvironmentKey
    // changes. macOS sets exactly this variable in a sandboxed process; any
    // other name would refuse every cleanup in a correctly sandboxed build.
    func testContainerIdentifierEnvironmentKey_matchesTheVariableMacOSSets() {
        XCTAssertEqual(SandboxTripwirePolicy.containerIdentifierEnvironmentKey, "APP_SANDBOX_CONTAINER_ID")
    }
}
