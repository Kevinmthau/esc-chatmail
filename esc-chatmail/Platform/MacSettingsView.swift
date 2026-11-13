#if os(macOS)
import SwiftUI

/// The Mac's Settings window (the app menu's Settings…, Command-Comma): the account, Sign
/// Out…, and the version (`MacSettingsPolicy`). It stands where the iOS app has its page in
/// the Settings app.
///
/// Sign Out… here is the app menu's command (`SignOutCommands`) as a button: it asks through
/// `SettingsAppSignOutController.requestSignOut` and ends in the same confirmation and the
/// same `AuthSession.signOut()`, so it adds no sign-out path. The window has a controller of
/// its own, as each window does, for two reasons:
/// - The confirmation is an alert on the window that asked. An alert raised from this view is
///   a sheet on the Settings window (measured in a stand-in program on macOS 27.2,
///   2026-11-13); raised from the mailbox window's controller it would come up on a window
///   that may be behind this one.
/// - While this window has the keyboard the mailbox window's focused values are not the
///   menu's, so this view publishes the menu command as well (`signOutMenuAction`). Without
///   that the app menu's Sign Out… would be disabled whenever Settings is in front.
///
/// A sign-out started here shows its progress here. The mailbox window draws its own overlay
/// only for a sign-out its own controller started, so the mailbox stays on screen, without
/// the overlay, until teardown replaces it with the sign-in view. Nothing sent or changed
/// there in that time gets through: `signOut()` closes admission before its first suspension.
///
/// HONEST SCOPE: nobody has seen this window. That the alert attaches to it was measured in
/// the stand-in program; the rest is read from the code.
struct MacSettingsView: View {
    @ObservedObject var authSession: AuthSession
    let version: String
    @StateObject private var signOut = SettingsAppSignOutController()

    init(
        authSession: AuthSession,
        version: String = SettingsAppPreferences.versionDisplayString(infoDictionary: Bundle.main.infoDictionary)
    ) {
        self.authSession = authSession
        self.version = version
    }

    var body: some View {
        let signOutAction = SignOutMenuAction(
            isEnabled: SignOutMenuPolicy.isEnabled(
                isAuthenticated: authSession.isAuthenticated,
                holdsAccountWhileSignedOut: signOut.holdsAccountWhileSignedOut,
                isSigningOut: signOut.isSigningOut
            ),
            controller: signOut,
            account: authSession
        )
        Form {
            Section {
                LabeledContent(
                    "Account",
                    value: MacSettingsPolicy.accountText(
                        isAuthenticated: authSession.isAuthenticated,
                        userEmail: authSession.userEmail
                    )
                )
                HStack {
                    Button("Sign Out…") {
                        signOutAction.perform()
                    }
                    .disabled(!signOutAction.isEnabled)
                    if signOut.isSigningOut {
                        ProgressView()
                            .controlSize(.small)
                        Text("Signing Out…")
                            .foregroundStyle(.secondary)
                    }
                }
            } footer: {
                Text(MacSettingsPolicy.signOutFootnote)
            }
            Section {
                LabeledContent("Version", value: version)
            }
        }
        .formStyle(.grouped)
        .frame(width: MacSettingsPolicy.windowWidth)
        .fixedSize(horizontal: false, vertical: true)
        .settingsAppSignOutAlerts(for: signOut)
        .signOutMenuAction(controller: signOut, account: authSession)
    }
}
#endif
