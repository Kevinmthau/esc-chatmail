#if os(macOS)
import SwiftUI

/// The Mac app menu's Sign Out… command. On iOS, Sign Out is a switch on the app's page in the
/// Settings app; the Mac has no such page, and until it has its own Settings scene
/// (`docs/mac-app-plan.md`, Phase 2) this command is the only way to sign out there.
///
/// It adds no sign-out path of its own: it raises the same request the iOS switch raises
/// (`SettingsAppSignOutController.requestSignOut`), so the confirmation alert and the single
/// `AuthSession.signOut()` are the ones `ContentView` already hosts. The title ends in an
/// ellipsis because choosing it asks for confirmation first.
struct SignOutCommands: Commands {
    @FocusedValue(\.signOutMenuAction) private var action

    var body: some Commands {
        CommandGroup(after: .appSettings) {
            Button("Sign Out…") {
                action?.perform()
            }
            .disabled(!(action?.isEnabled ?? false))
        }
    }
}
#endif
