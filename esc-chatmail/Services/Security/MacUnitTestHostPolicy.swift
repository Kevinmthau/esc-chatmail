import Foundation

/// Decides whether a Mac process that hosts unit tests may go on to run them.
/// `MacUnitTestHostGuard` applies it at the top of the app's `init`.
///
/// On the Mac the test host is the app itself, so a test run is a launch of
/// the app with the user's own files in reach:
/// - Outside the App Sandbox, the storage folders are the user's real
///   `~/Documents` and `~/Library/Application Support`
///   (`SandboxTripwirePolicy`).
/// - Inside it, they are the app's real container
///   (`~/Library/Containers/com.esc.inboxchat`), the one the Mac app the user
///   runs keeps its mail, preferences and keychain items in. Only the suites
///   in `Mac.xctestplan` are written to stay out of it. The full plan is
///   written for an iOS simulator, whose container holds nobody's mail.
///
/// `Scripts/run-tests.sh` checks both before it launches anything, but only
/// for runs that go through it. Cmd-U in Xcode with My Mac selected, or a
/// plain `xcodebuild test`, ran the full plan in a Mac host with no check at
/// all, signed or not. The host is the one place every run passes through, so
/// the decision is made here.
///
/// Pure and platform-neutral so it is unit-tested on iOS. Only the macOS guard
/// consults it.
enum MacUnitTestHostPolicy {
    /// `Mac.xctestplan` sets this variable in its test host's environment; no
    /// other test plan does (`MacUnitTestHostPolicyTests` pins both).
    static let macTestPlanEnvironmentKey = "ESC_CHATMAIL_MAC_TEST_PLAN"
    static let macTestPlanEnvironmentValue = "1"

    enum Verdict: Equatable, Sendable {
        /// A sandboxed host running `Mac.xctestplan`.
        case permitted
        /// No App Sandbox container. Checked first: this is the case that puts
        /// the user's own folders in reach.
        case refusedOutsideAppSandbox
        /// Sandboxed, but the test plan is not `Mac.xctestplan`.
        case refusedOutsideMacTestPlan
    }

    /// Permits a Mac test run only in the App Sandbox and only for
    /// `Mac.xctestplan`. Anything unclear refuses: not running tests is always
    /// safe.
    static func verdict(environment: [String: String]) -> Verdict {
        guard SandboxTripwirePolicy.destructiveCleanupVerdict(environment: environment) == .permitted else {
            return .refusedOutsideAppSandbox
        }
        guard environment[macTestPlanEnvironmentKey] == macTestPlanEnvironmentValue else {
            return .refusedOutsideMacTestPlan
        }
        return .permitted
    }
}
