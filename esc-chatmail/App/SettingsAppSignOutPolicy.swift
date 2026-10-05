import Foundation

/// Decides what the app does with the Settings app's Sign Out switch
/// (`SettingsAppPreferences.isSignOutRequested`) each time `ContentView`
/// re-evaluates it: on appear, on returning to the foreground, and when
/// authentication changes.
enum SettingsAppSignOutPolicy {
    enum Decision: Equatable {
        /// Nothing to do now; a pending request stays pending.
        case none
        /// Turn the switch back off without signing out.
        case discardRequest
        /// Ask the user to confirm signing out.
        case confirm
    }

    /// - Keys on `isAuthenticated`, not `canAccessMailbox`: a session waiting
    ///   on reauthentication still holds this account's credentials and mail,
    ///   so it can still be signed out (the prompt shows over `SignInView`).
    /// - Signed out → discard, checked before `isRequestBeingHandled`: there is
    ///   no session to sign out, and a request left on would prompt right after
    ///   the next sign-in. That also drops a switch turned on again while a
    ///   sign-out's cleanup is still finishing.
    /// - Already handling a request (prompt up or pending, sign-out running) →
    ///   none, so another foregrounding cannot stack a second prompt or a
    ///   second `signOut()`.
    /// - Scene not active → none: a background launch must not present UI; the
    ///   request waits for the next foregrounding.
    static func decision(
        isSignOutRequested: Bool,
        isAuthenticated: Bool,
        isRequestBeingHandled: Bool,
        isSceneActive: Bool
    ) -> Decision {
        guard isSignOutRequested else { return .none }
        guard isAuthenticated else { return .discardRequest }
        guard !isRequestBeingHandled, isSceneActive else { return .none }
        return .confirm
    }
}
