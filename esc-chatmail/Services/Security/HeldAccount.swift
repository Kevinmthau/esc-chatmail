import Foundation

/// An account whose launch restore failed in a way that keeps it: its credentials, store
/// and body files are all still on the device, and a later restore can bring it back
/// (`AuthSession.heldAccount`).
///
/// Before this existed the app showed the first-run sign-in screen over such an account
/// and never ran the restore again in the foreground, so a launch offline, or on a link
/// that could not reach Google's token endpoint, looked like a sign-out until the next
/// launch online (architecture review 2026-11, `account-boundary-auth#1`,
/// `startup-lifecycle#1`).
///
/// Holding an account publishes no session: `isAuthenticated` and `canAccessMailbox`
/// stay false, so nothing syncs, no background task is armed and no pending action
/// recovers. What it changes is the screen (`HeldAccountView`, which says the mail is
/// still on the device and offers Try Again) and whether the restore is run again by
/// itself (`LaunchRestoreRetryCoordinator`). Reading the stored mail while held would be
/// a seventh way to publish a session, which is a decision not taken.
struct HeldAccount: Equatable, Sendable {
    enum Failure: Equatable, Sendable {
        /// Google could not be reached: no network, a timeout, or Google's token
        /// endpoint failing or unavailable (`AuthSession.isConnectivityRestoreError`).
        case cannotConnect
        /// The restore stopped for a reason of this device's that a later attempt can
        /// get past: GoogleSignIn's keychain item could not be read (with the app's
        /// keychain naming an account), the mailbox could not be checked before
        /// publishing and nothing was changed (`AuthRestorePreparationPolicy`: the reset
        /// marker unreadable, the store uninspectable), or a reopen step failed
        /// (`.transientFailure`).
        case couldNotRestore
    }

    /// The account's address as the app's keychain holds it. Nil when it could not be
    /// read; the account is held all the same.
    let email: String?
    let failure: Failure
}
