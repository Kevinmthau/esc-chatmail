import Foundation

/// Where `AuthSession.prepareLocalStoreForAuthenticatedAccount` stopped when it refused
/// an account, carried by `AuthError.localAccountIsolationFailed`.
///
/// The stage says whether the refusal changed anything, which is what a launch restore
/// needs to know before it decides what to do with the Google session it has just
/// restored (`AuthRestorePreparationPolicy`). Before the stage existed every refusal
/// looked the same, and the restore cleared the session for all of them, so a keychain
/// read that failed once signed the user out over an intact mailbox (architecture review
/// 2026-11, `account-boundary-auth#4`).
///
/// The raw value is for the log and names no account.
enum LocalAccountIsolationStage: String, CaseIterable, Sendable {
    /// The durable local-cleanup marker could not be read, so its absence is not proven.
    /// Nothing was changed: the store was not inspected, and nothing was written.
    case markerUnreadable
    /// The mailbox store (its Account rows, its other rows, its files) could not be
    /// inspected. Nothing was changed.
    case storeUninspectable
    /// The store holds mail this account must not see (another account's, or rows and
    /// files no Account row owns), and the marker that makes its reset crash-durable could
    /// not be written, so the reset never began. Nothing was changed yet, but the store is
    /// not this account's to open: a retry with the same session would reset it unasked,
    /// behind a screen saying the mail is still on the device.
    case resetRequired
    /// The reset ran after its marker was persisted and did not finish: the credentials,
    /// the store, the body or attachment files may be partly gone, and the marker makes
    /// the next launch finish the sign-out. A sign-out that arrived meanwhile ends the
    /// reset here too, with a `CancellationError`.
    case resetFailed
    /// The empty store a recovery reset left beside this account's files
    /// (`StoreRecoveryResetMarker`) could not have all of them removed: some may be gone.
    /// A sign-out that arrived meanwhile ends the removal here too.
    case recoveryFileRemovalFailed
}
