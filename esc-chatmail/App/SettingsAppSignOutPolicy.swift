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

    /// Whether a confirmation answered with Sign Out still stands for the session as it is
    /// now. `asked` is what the confirmation was raised about, `current` what the sign-out
    /// would end. The controller asks when the user answers, and before that whenever it is
    /// told about the session, to take down a confirmation whose answer would not stand
    /// (`SettingsAppSignOutController.withdrawStaleConfirmation`).
    ///
    /// A confirmation can outlive what it asked about. The Mac's Settings window shows its
    /// confirmation as a sheet on that window only, so the mailbox window still takes clicks
    /// while it is up: raised over an account held while signed out (a launch restore that
    /// failed retryably), it stayed up while the user signed in on the mailbox window, and
    /// its Sign Out button then signed that new session out.
    ///
    /// - Nobody is signed in now → it stands. What is left is the account it asked about,
    ///   still held, and the caller has already dropped the case where nothing is left
    ///   (`isDurablySignedOut()`). A signed-in session that now needs reauthentication is
    ///   still signed in here, so it never reaches this line as another account.
    /// - Signed in now but not when asked → it does not. Two things get there once the app
    ///   has started. A sign-in finished after the question, as the same account or another.
    ///   Or the launch restore that failed was run again and brought the held account back:
    ///   an iOS background task does that, because `AppStartupBootstrap` runs a restore
    ///   again until one is complete. The two are not told apart here, so the question is
    ///   not answered as it was asked in either. Where the request is stored (the iOS
    ///   switch) the controller asks again, naming the account that is signed in, and that
    ///   answer stands. Before it did, the restored account's own sign-out was refused,
    ///   with the switch turned off and nothing asked again.
    /// - Signed in both times → it stands unless both addresses are known and differ. They
    ///   are compared without case, as addresses are. One of them unknown is not a
    ///   difference: refusing there would refuse a sign-out nothing shows to be wrong.
    ///
    /// The same address signed out and in again between the question and the answer is not
    /// seen. The confirmation then names the account it signs out.
    static func answerStillApplies(
        asked: SettingsAppSignOutSubject,
        current: SettingsAppSignOutSubject
    ) -> Bool {
        guard current.isAuthenticated else { return true }
        guard asked.isAuthenticated else { return false }
        guard let askedEmail = asked.email, let currentEmail = current.email else { return true }
        return askedEmail.caseInsensitiveCompare(currentEmail) == .orderedSame
    }
}
