import Foundation
import os.log

/// The screen `ContentView` publishes as the app's root, named so that something outside
/// the process can see which one came up (architecture review 2026-11,
/// testing-ci-release#2, part 2).
///
/// The real launch path (`esc_chatmailApp.init`, `initializeApp()`, `ContentView`) runs
/// under no test plan, and the Release build was first launched by the TestFlight install
/// after the merge. CI now launches the Release build on an erased simulator
/// (`Scripts/launch-smoke.sh`) and asks three things of it: that the process is still
/// alive after a fixed wait, that it wrote no crash report, and that it published the
/// sign-in root. The third needs a witness a Release build leaves outside the process,
/// so `ContentView` gives its root view this identifier and `LaunchRootScreenRecord`
/// writes the same identifier to the unified log, where `log show` reads it.
///
/// The decision is here, not in `ContentView`'s `if`/`else`, so that it can be pinned on
/// its own (`LaunchRootScreenTests`); `ContentView` reads it for the identifier and the
/// record, and its branches follow the same order.
enum LaunchRootScreen: String, CaseIterable, Equatable, Sendable {
    /// `MailboxRootView`: the session can access the mailbox.
    case mailbox = "launch.root.mailbox"
    /// `HeldAccountView`: the launch restore kept the account but could not reach Google.
    case heldAccount = "launch.root.heldAccount"
    /// `SignInView`: no session and no held account, the first run's screen.
    case signIn = "launch.root.signIn"

    /// `ContentView`'s choice: the mailbox whenever the session can access it, the held
    /// account's screen when there is one and no session, the sign-in screen otherwise.
    static func screen(canAccessMailbox: Bool, hasHeldAccount: Bool) -> LaunchRootScreen {
        if canAccessMailbox {
            return .mailbox
        }
        if hasHeldAccount {
            return .heldAccount
        }
        return .signIn
    }

    /// What the root view carries, and what the record names.
    var accessibilityIdentifier: String { rawValue }
}

/// Writes the published root screen to the unified log, once per publication.
///
/// This is not `Log`: a Release build logs `Log.warning` and above only, and a screen
/// coming up is no warning. It is one `notice` line per launch (and per later change of
/// root, a sign-in or a sign-out), persisted by the log store as every default-level line
/// is, so `log show --predicate 'subsystem == "<bundle id>" AND category == "launch"'`
/// finds it after the fact; an `info` line would need a live `log stream` started before
/// the launch. Like `ChatViewPerformanceSignposts`, it writes an identifier the app made
/// and nothing from the mailbox. `Scripts/launch-smoke.sh` greps for the line; the script
/// and this type spell it the same (`LaunchSmokeSourceTests`).
enum LaunchRootScreenRecord {
    static let subsystem = Bundle.main.bundleIdentifier ?? "com.esc.inboxchat"
    static let category = "launch"
    static let messagePrefix = "Root screen published: "

    private static let logger = Logger(subsystem: subsystem, category: category)

    static func record(_ screen: LaunchRootScreen) {
        logger.notice("\(messagePrefix, privacy: .public)\(screen.accessibilityIdentifier, privacy: .public)")
    }
}
