#if os(macOS)
import AppKit
import SwiftUI

/// What the Mac's Sign Out… menu command does for the focused window. `ContentView` publishes it
/// (`View.signOutMenuAction(controller:account:)`) and `SignOutCommands` reads it, because the
/// command lives on the scene while the sign-out controller belongs to the window's root view.
///
/// It is a value of `isEnabled` and two object references, and compares equal until one of them
/// changes. It held a closure before, which never compares equal, so every `AuthSession` publish
/// republished it and re-ran `SignOutCommands.body`.
struct SignOutMenuAction: Equatable {
    /// `SignOutMenuPolicy.isEnabled`.
    let isEnabled: Bool
    private let controller: SettingsAppSignOutController
    private let account: AuthSession

    init(isEnabled: Bool, controller: SettingsAppSignOutController, account: AuthSession) {
        self.isEnabled = isEnabled
        self.controller = controller
        self.account = account
    }

    /// The command was chosen. Beeps when nothing is asked (`SignOutMenuPolicy.choice`), so a
    /// choice made under an open sheet does not look ignored.
    @MainActor
    func perform() {
        let choice = controller.requestSignOut(
            account: account,
            focusedWindowHasSheet: FocusedWindowSheet.isAttached
        )
        if choice == .refuse {
            NSSound.beep()
        }
    }

    static func == (lhs: SignOutMenuAction, rhs: SignOutMenuAction) -> Bool {
        lhs.isEnabled == rhs.isEnabled && lhs.controller === rhs.controller && lhs.account === rhs.account
    }
}
#endif
