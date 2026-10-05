import Foundation

/// The app's side of `Resources/Settings.bundle` (Settings → MushMail): the
/// values the Settings app displays, and the Sign Out switch it writes back.
/// The account and Sign Out live there because the app has no in-app settings
/// screen.
///
/// Both sides share the app's own defaults domain (`UserDefaults.standard`),
/// so these keys must match the bundle's `Root.plist` exactly — pinned by
/// `SettingsAppPreferencesTests`.
///
/// The app must clear the Sign Out request itself on every outcome: no
/// `AuthSession` teardown path removes arbitrary defaults keys (only a fresh
/// install wipes the domain), so a request left on would prompt again right
/// after the next sign-in. `SettingsAppSignOutPolicy` decides when.
struct SettingsAppPreferences {
    static let accountEmailKey = "settingsApp.accountEmail"
    static let signOutRequestedKey = "settingsApp.signOutRequested"
    static let versionKey = "settingsApp.version"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Whether the Settings app's Sign Out switch is on. An absent value reads
    /// `false`, matching the switch's `DefaultValue` (the Settings app does not
    /// register a bundle's defaults with the app).
    var isSignOutRequested: Bool {
        defaults.bool(forKey: Self.signOutRequestedKey)
    }

    /// Turns the Settings app's Sign Out switch back off.
    func clearSignOutRequest() {
        defaults.removeObject(forKey: Self.signOutRequestedKey)
    }

    /// Shows `email` as the account in the Settings app; nil removes the value
    /// so the row falls back to its "Not Signed In" default. Writes only on
    /// change, since it runs on every authentication change.
    func publishAccountEmail(_ email: String?) {
        guard defaults.string(forKey: Self.accountEmailKey) != email else { return }
        if let email {
            defaults.set(email, forKey: Self.accountEmailKey)
        } else {
            defaults.removeObject(forKey: Self.accountEmailKey)
        }
    }

    func publishAppVersion(_ version: String) {
        guard defaults.string(forKey: Self.versionKey) != version else { return }
        defaults.set(version, forKey: Self.versionKey)
    }

    /// The account the Settings app should show: the trimmed email while a
    /// session exists, otherwise nil ("Not Signed In"). Requiring
    /// `isAuthenticated` keeps a leftover `userEmail` from naming an account
    /// the app is no longer signed in to.
    static func displayedAccountEmail(isAuthenticated: Bool, userEmail: String?) -> String? {
        guard isAuthenticated,
              let email = userEmail?.trimmingCharacters(in: .whitespacesAndNewlines),
              !email.isEmpty else {
            return nil
        }
        return email
    }

    /// "1.0 (1)" from the marketing version and build number, the marketing
    /// version alone without a build, and "Unknown" without a marketing
    /// version (what the old in-app Settings screen showed).
    static func versionDisplayString(infoDictionary: [String: Any]?) -> String {
        guard let shortVersion = infoDictionary?["CFBundleShortVersionString"] as? String,
              !shortVersion.isEmpty else {
            return "Unknown"
        }
        guard let build = infoDictionary?["CFBundleVersion"] as? String, !build.isEmpty else {
            return shortVersion
        }
        return "\(shortVersion) (\(build))"
    }
}
