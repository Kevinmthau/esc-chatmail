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
    /// The store has to be reset before this account may open it, and the marker that
    /// makes the reset crash-durable could not be written, so this preparation began no
    /// reset and changed nothing. Either reason for the reset makes the store not this
    /// account's to open. The inspection found mail this account must not see (another
    /// account's, or rows and files no Account row owns): a retry with the same session
    /// would reset it unasked, behind a screen saying the mail is still on the device.
    /// Or a marker an earlier sign-out or failed reset persisted already asks for the
    /// reset, and the store was not inspected: that reset may have removed part of the
    /// mailbox already, and its marker, which a failed write leaves in place
    /// (`KeychainService.save` updates an existing item, never deletes it), makes the next
    /// launch finish it. A launch restore meets the second only behind a sign-out
    /// registered since its start, because the restore resumes an earlier reset before it
    /// prepares the store.
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
