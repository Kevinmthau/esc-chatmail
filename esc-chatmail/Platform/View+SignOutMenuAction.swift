import SwiftUI

extension View {
    /// Publishes what the Mac's Sign Out… menu command (`SignOutCommands`) does while this view's
    /// window is focused. Changes nothing on iOS, where Sign Out is a switch in the Settings app
    /// and there is no menu command to feed.
    @ViewBuilder
    func signOutMenuAction(isEnabled: Bool, perform: @escaping @MainActor () -> Void) -> some View {
        #if os(macOS)
        focusedSceneValue(\.signOutMenuAction, SignOutMenuAction(isEnabled: isEnabled, perform: perform))
        #else
        self
        #endif
    }
}
