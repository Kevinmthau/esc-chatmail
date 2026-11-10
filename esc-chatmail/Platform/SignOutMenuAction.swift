#if os(macOS)
import SwiftUI

/// What the Mac's Sign Out… menu command does for the focused window. `ContentView` publishes it
/// (`View.signOutMenuAction(isEnabled:perform:)`) and `SignOutCommands` reads it, because the
/// command lives on the scene while the sign-out controller belongs to the window's root view.
struct SignOutMenuAction {
    /// `SignOutMenuPolicy.isEnabled`.
    let isEnabled: Bool
    let perform: @MainActor () -> Void
}

private struct SignOutMenuActionKey: FocusedValueKey {
    typealias Value = SignOutMenuAction
}

extension FocusedValues {
    /// Nil while no window is focused, which leaves the menu command disabled.
    var signOutMenuAction: SignOutMenuAction? {
        get { self[SignOutMenuActionKey.self] }
        set { self[SignOutMenuActionKey.self] = newValue }
    }
}
#endif
