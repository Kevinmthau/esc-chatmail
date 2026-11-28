import Foundation

/// Decides what a launch restore does with the Google session it restored when
/// `AuthSession.prepareLocalStoreForAuthenticatedAccount` refused the account.
///
/// Until 2026-11-27 every refusal cleared the session (`clearFailedGoogleSession`: the SDK
/// signed out, the tokens deleted, the signed-out verdict persisted, the sync timestamps
/// dropped), so the next restore ended signed out. A reset marker that could not be read
/// once, or a store that could not be inspected, changed nothing and still forced a new
/// sign-in over an intact mailbox (architecture review 2026-11, `account-boundary-auth#4`).
/// A refusal that changed nothing now keeps the credentials, as a transient reopen failure
/// does (`AuthRestoreReopenPolicy`); the restore then holds the account (`HeldAccount`)
/// and a later attempt asks again. A refusal that changed something, or that a retry with
/// the same session cannot get past, still clears them.
///
/// Three things are not asked here. A queued sign-out is checked first, by the restore:
/// it owns the teardown, credentials included, and its cleanup's `CancellationError`
/// reaches the restore wrapped as a failed reset, so the restore clears nothing then.
/// Credential persistence is not a preparation: once its marker may be persisted, the next
/// launch rejects the session by design, so its failure always clears. And interactive
/// sign-in stays all-or-none: it clears the session it just replaced on any refusal.
///
/// A pure namespace, so the decision is testable without a `GIDGoogleUser`.
enum AuthRestorePreparationPolicy {
    typealias RestoreDisposition = AuthRestoreReopenPolicy.RestoreDisposition

    /// The disposition for an error `prepareLocalStoreForAuthenticatedAccount` threw.
    /// Never `.publishSession`: a refused account is never published.
    static func restoreDisposition(afterPreparationFailure error: Error) -> RestoreDisposition {
        guard let stage = (error as? AuthError)?.localAccountIsolationStage else {
            // `missingAccountEmail`: the account cannot be checked against the store, now
            // or on any later attempt. Anything else is not a refusal this policy knows,
            // and fails closed as every refusal did before it existed.
            return .discardCredentials
        }
        return restoreDisposition(after: stage)
    }

    static func restoreDisposition(after stage: LocalAccountIsolationStage) -> RestoreDisposition {
        switch stage {
        case .markerUnreadable, .storeUninspectable:
            // Nothing was read as an answer and nothing was written. The restore that
            // just ran had already read the same marker at its start, and the store had
            // loaded before it, so the fault is a transient one a later attempt can get
            // past with exactly these credentials.
            return .retryKeepingCredentials
        case .resetRequired:
            // The store is not this account's to open: a retry would reset another
            // account's mail unasked, or open a mailbox an earlier reset left half removed.
            // The user signs in again, and that sign-in's preparation resets the store.
            return .discardCredentials
        case .resetFailed, .recoveryFileRemovalFailed:
            // Something is already gone. After a failed reset the persisted marker makes
            // the next launch finish the sign-out by design, so the outcome stays a
            // rejection; after a partial removal of a recovery's files the cleared session
            // is what makes the next attempt run the full cleanup.
            return .discardCredentials
        }
    }
}
