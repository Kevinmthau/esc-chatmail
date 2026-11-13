#if os(macOS)
import SwiftUI

/// The Mac app menu's Sign Out… command. On iOS, Sign Out is a switch on the app's page in the
/// Settings app; the Mac has no such page. Its Settings window (`MacSettingsView`) has the same
/// command as a button, and publishes this one too, so it can be chosen with either window in
/// front.
///
/// It adds no sign-out path of its own: it asks through the controller the iOS switch is judged
/// by (`SettingsAppSignOutController.requestSignOut`), so the confirmation alert and the single
/// `AuthSession.signOut()` are the ones `ContentView` already hosts. Unlike the switch it stores
/// no request. The title ends in an ellipsis because choosing it asks for confirmation first.
///
/// Chosen while the focused window has a sheet attached, it beeps and asks nothing
/// (`SignOutMenuPolicy.choice`).
///
/// HONEST SCOPE: nobody has seen this command on screen, and no test mounts it. Whether SwiftUI
/// keeps the focused value while a sheet is the key window was not measured, because measuring it
/// needs a key window. Either answer is handled: without the value the command is disabled, and
/// with it `SignOutMenuAction.perform()` refuses.
struct SignOutCommands: Commands {
    @FocusedValue(\.signOutMenuAction) private var action

    var body: some Commands {
        // Before the Services group, in a group of its own, which puts it under Settings… and
        // its separator. `after: .appSettings` put it above the Settings… item the Settings
        // scene adds (read from the test host's menu bar on macOS 27.2, 2026-11-13;
        // `MacSettingsMenuTests`).
        CommandGroup(before: .systemServices) {
            Button("Sign Out…") {
                action?.perform()
            }
            .disabled(!(action?.isEnabled ?? false))
            Divider()
        }
    }
}
#endif
