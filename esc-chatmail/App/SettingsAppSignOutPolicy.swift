import Foundation

/// Decides what the app does with the Settings app's Sign Out switch
/// (`SettingsAppPreferences.isSignOutRequested`) each time
/// `SettingsAppSignOutController` evaluates it for `ContentView`: on appear, on
/// returning to the foreground or regaining focus, and when authentication
/// changes.
enum SettingsAppSignOutPolicy {
    enum Decision: Equatable {
        /// Nothing to do now; a pending request stays pending.
        case none
        /// Turn the switch back off without signing out.
        case discardRequest
        /// Ask the user to confirm signing out.
        case confirm
    }

    /// - Keys on `AuthSession.isDurablySignedOut()`, not `isAuthenticated` or
    ///   `canAccessMailbox`: a session waiting on reauthentication, and an
    ///   account whose launch restore failed retryably (offline with an expired
    ///   token: `SignInView` shows, yet the credentials, store and body files
    ///   all remain and a later restore brings the account back), still hold
    ///   this account on the device, so they can still be signed out — the
    ///   prompt shows over `SignInView`. Discarding there would turn the switch
    ///   off while nothing was removed.
    /// - Durably signed out → discard, checked before `isRequestBeingHandled`:
    ///   no session remains for the switch to end (the Settings app's Account
    ///   row reads Not Signed In), and a request left on would prompt right after
    ///   the next sign-in (no teardown path clears the key). That also drops a
    ///   switch turned on again while a confirmed sign-out is still cleaning
    ///   up, since `isDurablySignedOut()` turns true as soon as the sign-out
    ///   registers. Discarding is not a promise that nothing is left on the
    ///   device: a launch restore whose credentials were rejected
    ///   (`AuthSession.clearFailedGoogleSession`: invalid_grant or a missing
    ///   Gmail scope) deliberately keeps the store and body files for the same
    ///   account's re-sign-in, and only a different account's sign-in resets
    ///   them (`prepareLocalStoreForAuthenticatedAccount`). This switch does
    ///   not remove them; it ends sessions, as the old in-app Sign Out did.
    /// - Already handling a request (prompt up or pending, sign-out running) →
    ///   none, so another evaluation cannot stack a second prompt or a second
    ///   `signOut()`.
    /// - Scene not active → none: a background launch must not present UI; the
    ///   request waits for the next foregrounding.
    static func decision(
        isSignOutRequested: Bool,
        isDurablySignedOut: Bool,
        isRequestBeingHandled: Bool,
        isSceneActive: Bool
    ) -> Decision {
        guard isSignOutRequested else { return .none }
        guard !isDurablySignedOut else { return .discardRequest }
        guard !isRequestBeingHandled, isSceneActive else { return .none }
        return .confirm
    }
}
