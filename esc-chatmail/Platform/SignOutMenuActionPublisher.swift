#if os(macOS)
import SwiftUI

/// Publishes the Mac's Sign Out… menu command for the window it is applied to
/// (`View.signOutMenuAction(controller:account:)`), and keeps the controller's cached
/// "an account is still held" answer current for it.
///
/// The cache is renewed where `ContentView` already looks at the account: when the window
/// appears and when authentication changes. Not on every focus change, which is frequent on the
/// Mac and would read the keychain each time while signed out. An answer that goes stale between
/// those moments is harmless (`SignOutMenuPolicy.isEnabled`).
struct SignOutMenuActionPublisher: ViewModifier {
    @ObservedObject var controller: SettingsAppSignOutController
    @ObservedObject var account: AuthSession

    func body(content: Content) -> some View {
        content
            .focusedSceneValue(
                \.signOutMenuAction,
                SignOutMenuAction(controller: controller, account: account)
            )
            .onAppear {
                controller.refreshHeldAccount(account: account)
            }
            .onChange(of: account.isAuthenticated) {
                controller.refreshHeldAccount(account: account)
            }
    }
}
#endif
