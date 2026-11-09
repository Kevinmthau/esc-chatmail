#if os(macOS)
import Foundation

/// Applies `MacUnitTestHostPolicy` to this process: a Mac unit-test host that
/// the policy refuses exits before the app or any test touches the disk.
///
/// `esc_chatmailApp.init` calls it first, before the app sets anything up and
/// before any test runs. It exits rather than traps: a refused run is a wrong
/// invocation, not a crash, and a trap would put up the system's crash dialog.
/// Outside a unit-test host it does nothing.
enum MacUnitTestHostGuard {
    static func exitUnlessPermitted(
        isRunningUnitTests: Bool = RuntimeEnvironment.isRunningUnitTests,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        guard isRunningUnitTests else { return }

        let reason: String
        switch MacUnitTestHostPolicy.verdict(environment: environment) {
        case .permitted:
            return
        case .refusedOutsideAppSandbox:
            reason = "This test host has no \(SandboxTripwirePolicy.containerIdentifierEnvironmentKey), so it is not in an App Sandbox container and its Documents and Application Support folders are the user's own. Sign the build with the team; never run Mac tests from a CODE_SIGNING_ALLOWED=NO build."
        case .refusedOutsideMacTestPlan:
            reason = "This test host was not started by Mac.xctestplan (\(MacUnitTestHostPolicy.macTestPlanEnvironmentKey) is not set). Only that plan's suites stay out of the app's real container; the other plans run on an iOS simulator. In Xcode, pick the Mac test plan."
        }
        Log.error(
            "Mac test host: refusing to run tests. \(reason) Run them with DESTINATION='platform=macOS' ./Scripts/codex-test.sh.",
            category: .general
        )
        exit(EXIT_FAILURE)
    }
}
#endif
