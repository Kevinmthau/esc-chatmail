import Combine
import Foundation

/// What the app's sign-out controllers share. Each window has a `SettingsAppSignOutController`
/// of its own, so that a confirmation is an alert on the window that asked, and on the Mac
/// there are two such windows: the mailbox and Settings (`MacSettingsView`). Three things
/// about a sign-out belong to the app and not to the window that started it:
///
/// - **That one is running.** A controller knew only about its own, so while a sign-out
///   started in Settings ran, the mailbox window's Sign Out… command stayed enabled, and
///   choosing it beeped with nothing to say why. Every controller's command is disabled from
///   this (`SettingsAppSignOutController.isAnySignOutRunning`).
/// - **That one is being asked about.** Sign Out… asks nothing in one window while the
///   other's confirmation is up (`isConfirmationActiveInAnyWindow()`).
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

    /// Each controller's answer to "is your confirmation up?", nil once that controller has
    /// gone (`addConfirmationSource`).
    private var confirmationSources: [@MainActor () -> Bool?] = []

    var isSigningOut: Bool {
        runningSignOutCount > 0
    }

    /// Names a window's confirmation, so another window's Sign Out… can know it is up.
    /// `isActive` answers nil once its controller has gone, and is then forgotten.
    func addConfirmationSource(_ isActive: @escaping @MainActor () -> Bool?) {
        confirmationSources.append(isActive)
    }

    /// Whether any window's sign-out confirmation is up. A controller knew only about its
    /// own, so with the Settings window's confirmation up, Sign Out… chosen with the mailbox
    /// window in front asked again. The first alert was then still up when the second one's
    /// sign-out had finished, and after a new sign-in it named the old account and signed
    /// the new one out.
    ///
    /// Asked of every prompter at the moment it is called. It is never kept or counted: an
    /// alert can leave the screen without either of its handlers running, and a count left
    /// above zero would refuse every later Sign Out….
    func isConfirmationActiveInAnyWindow() -> Bool {
        var isActive = false
        confirmationSources.removeAll { source in
            guard let answer = source() else { return true }
            isActive = isActive || answer
            return false
        }
        return isActive
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
