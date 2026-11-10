import SwiftUI

extension View {
    /// Publishes the Mac's Sign Out… menu command (`SignOutCommands`) for this view's window:
    /// what it does (`SignOutMenuAction`) and whether it can be chosen. Changes nothing on iOS,
    /// where Sign Out is a switch in the Settings app and there is no menu command to feed.
    func signOutMenuAction(controller: SettingsAppSignOutController, account: AuthSession) -> some View {
        #if os(macOS)
        modifier(SignOutMenuActionPublisher(controller: controller, account: account))
        #else
        self
        #endif
    }
}
