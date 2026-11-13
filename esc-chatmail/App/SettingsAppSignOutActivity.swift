import Combine
import Foundation

/// What the app's sign-out controllers share. Each window has a `SettingsAppSignOutController`
/// of its own, so that a confirmation is an alert on the window that asked, and on the Mac
/// there are two such windows: the mailbox and Settings (`MacSettingsView`). Two things
/// about a sign-out belong to the app and not to the window that started it:
///
/// - **That one is running.** A controller knew only about its own, so while a sign-out
///   started in Settings ran, the mailbox window's Sign Out… command stayed enabled, and
///   choosing it beeped with nothing to say why. Every controller's command is disabled from
///   this (`SettingsAppSignOutController.isAnySignOutRunning`).
/// - **Where a failure is shown when the window that started it has gone.** The Settings
///   window can be closed while its sign-out runs, and its alert then has no window to
///   appear on. The mailbox window is there for as long as the Mac app runs (closing it
///   quits), so its controller takes such a failure (`showFailureInFallbackWindow()`).
///
/// iOS has one controller per window too, but its prompter presents from the topmost view
/// controller, so nothing there asks for the fallback.
@MainActor
final class SettingsAppSignOutActivity: ObservableObject {
    static let shared = SettingsAppSignOutActivity()

    /// Confirmed sign-outs between `signOutDidBegin()` and `signOutDidEnd()`. A count, not a
    /// flag: nothing lets two run at once today (`signOutConfirmed` refuses once the account
    /// is durably signed out), but if two did, the first to end must not report the other as
    /// over.
    @Published private(set) var runningSignOutCount = 0

    private var failureFallback: (@MainActor () -> Bool)?

    var isSigningOut: Bool {
        runningSignOutCount > 0
    }

    /// Every `signOutDidBegin()` is followed by exactly one `signOutDidEnd()`, on every
    /// outcome of the sign-out: a count left above zero would disable Sign Out… in every
    /// window until the app is quit.
    func signOutDidBegin() {
        runningSignOutCount += 1
    }

    func signOutDidEnd() {
        guard runningSignOutCount > 0 else { return }
        runningSignOutCount -= 1
    }

    /// Names the window that shows a failure whose own window is off screen. `show` returns
    /// false when it showed nothing (its controller has gone). A later call replaces an
    /// earlier one.
    func setFailureFallback(_ show: @escaping @MainActor () -> Bool) {
        failureFallback = show
    }

    /// Shows a sign-out failure in the fallback window. False when there is none to show it,
    /// which leaves the failure with the caller.
    func showFailureInFallbackWindow() -> Bool {
        failureFallback?() ?? false
    }
}
