import Foundation

/// What the Mac's Settings window (`MacSettingsView`) shows. The same three things as the
/// iOS app's page in the Settings app (`Resources/Settings.bundle`): the account, a way to
/// sign out, and the version.
enum MacSettingsPolicy {
    /// What the Account row shows with nobody signed in: the words the iOS Settings page
    /// shows (`Root.plist`'s default for the row).
    static let signedOutAccountText = "Not Signed In"

    /// The line under the Sign Out… button. The iOS page's footer, without the half about
    /// its switch.
    static let signOutFootnote = "Signing out removes this account’s mail from this Mac."

    /// The window's width. A Settings window is as tall as its content and cannot be
    /// resized.
    static let windowWidth: CGFloat = 420

    /// The Account row: the signed-in address, or `signedOutAccountText`. The address is
    /// judged as the iOS page's is (`SettingsAppPreferences.displayedAccountEmail`), so an
    /// address left over from a session that has ended is not shown.
    static func accountText(isAuthenticated: Bool, userEmail: String?) -> String {
        SettingsAppPreferences.displayedAccountEmail(isAuthenticated: isAuthenticated, userEmail: userEmail)
            ?? signedOutAccountText
    }
}
