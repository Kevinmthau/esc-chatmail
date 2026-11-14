#if os(macOS)
import AppKit
import SwiftUI

/// What the Mac's Sign Out… menu command does for the focused window. `ContentView` publishes it
/// (`View.signOutMenuAction(controller:account:)`) and `SignOutCommands` reads it, because the
/// command lives on the scene while the sign-out controller belongs to the window's root view.
/// The Settings window publishes its own, and its Sign Out… button is the same value
/// (`MacSettingsView`).
///
/// Whether it can be chosen is decided here and nowhere else (`init(controller:account:)`), so
/// a window's button and its menu command cannot disagree.
///
/// It is a value of `isEnabled` and two object references, and compares equal until one of them
/// changes. It held a closure before, which never compares equal, so every `AuthSession` publish
/// republished it and re-ran `SignOutCommands.body`.
struct SignOutMenuAction: Equatable {
    /// `SignOutMenuPolicy.isEnabled`.
    let isEnabled: Bool
    private let controller: SettingsAppSignOutController
    private let account: AuthSession

    /// Disabled while any window's sign-out is running, not only this controller's
    /// (`SettingsAppSignOutController.isAnySignOutRunning`).
    @MainActor
    init(controller: SettingsAppSignOutController, account: AuthSession) {
        self.isEnabled = SignOutMenuPolicy.isEnabled(
            isAuthenticated: account.isAuthenticated,
            holdsAccountWhileSignedOut: controller.holdsAccountWhileSignedOut,
            isSigningOut: controller.isAnySignOutRunning
        )
        self.controller = controller
        self.account = account
    }

    /// The command was chosen. Beeps when nothing is asked (`SignOutMenuPolicy.choice`), so a
    /// choice made under an open sheet does not look ignored. The sheet may be on the focused
    /// window or on the mailbox window behind the Settings window (`MailboxWindowSheet`).
    ///
    /// A sheet on a window that is not the focused one can be out of sight, the other
    /// window's confirmation included, so a refusal also brings that window to the front
    /// (`SheetBehindFocusedWindow`): the beep alone said nothing of what was in the way.
    @MainActor
    func perform() {
        let choice = controller.requestSignOut(
            account: account,
            focusedWindowHasSheet: FocusedWindowSheet.isAttached || MailboxWindowSheet.isAttached
        )
        if choice == .refuse {
            NSSound.beep()
            SheetBehindFocusedWindow.reveal()
        }
    }

    static func == (lhs: SignOutMenuAction, rhs: SignOutMenuAction) -> Bool {
        lhs.isEnabled == rhs.isEnabled && lhs.controller === rhs.controller && lhs.account === rhs.account
    }
}
#endif
