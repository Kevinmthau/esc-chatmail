import Foundation

/// Decides whether the Mac's Sign Out… menu command (`SignOutCommands`) can be chosen.
enum SignOutMenuPolicy {
    /// - Signed in → enabled. That includes a session waiting on reauthentication, which keeps
    ///   `isAuthenticated` true and is still an account on this Mac.
    /// - A confirmed sign-out already running → disabled, so the command reads as busy instead of
    ///   raising a request `SettingsAppSignOutPolicy` would only hold.
    /// - Not signed in → disabled. That also covers a launch restore that failed retryably, where
    ///   the account is still on the Mac behind `SignInView`: `isDurablySignedOut()` could tell the
    ///   two apart, but it reads the keychain and this runs in a view body. That account is signed
    ///   out by signing in again first.
    static func isEnabled(isAuthenticated: Bool, isSigningOut: Bool) -> Bool {
        isAuthenticated && !isSigningOut
    }
}
