import Foundation

/// Decides what the launch screen says when the mailbox store could not be
/// opened, and when it offers to reset the mailbox. Every load failure that
/// reaches the screen left the store latched for a retry
/// (`PersistentStoreLoadError`), so the screen always offers one.
///
/// Reset Mailbox exists because a load error outside
/// `CoreDataErrorClassifier`'s reset allow-list keeps the store, and a
/// permanent one (a store type mismatch, an I/O or can't-open error that
/// never clears) would otherwise leave the user on this screen for good,
/// with deleting the app, which loses the same data, as the only way out.
enum AppLoadingPolicy {
    struct StoreLoadFailureNotice: Equatable {
        let title: String
        let message: String
        /// Shows Reset Mailbox beside Try Again.
        let offersMailboxReset: Bool
    }

    /// What a load failure says about the way out of it.
    enum StoreLoadFailureKind: Equatable {
        /// The device is full, or nearly. Freeing space is the fix and keeps
        /// the user's data, so a reset is never offered.
        case insufficientStorage
        /// The store was kept on disk and could not be opened
        /// (`PersistentStoreLoadError.unavailable`). Retrying may fix it; if
        /// it never does, only a reset can.
        case storeUnavailable
        /// Any other error. `CoreDataStack.resetStoreAfterLoadFailure()`
        /// refuses to reset these, so the screen does not offer it.
        case other
    }

    struct MailboxResetConfirmation: Equatable {
        let title: String
        let message: String
        let confirmButtonTitle: String
    }

    /// Below this much free space an open failure is presented as a full
    /// device even when the error does not say so: at 0 bytes free SQLite
    /// reports SQLITE_CANTOPEN rather than SQLITE_FULL.
    static let lowStorageThresholdBytes: Int64 = 200 * 1024 * 1024

    /// Consecutive `.storeUnavailable` failures before the screen offers
    /// Reset Mailbox. The launch retry loop's backoff alone reaches five about
    /// 15 s after the first failure (waits of 1, 2, 4 and 8 s), so a transient
    /// fault has had several chances to clear first; each Try Again counts
    /// too, so a user who keeps tapping it gets there sooner.
    static let mailboxResetFailureThreshold = 5

    static let mailboxResetConfirmation = MailboxResetConfirmation(
        title: "Reset Mailbox?",
        message: "MushMail will delete its copy of your mailbox on this device and download your mail again from Gmail. Changes that haven't synced yet, drafts, and messages that haven't finished sending will be lost.",
        confirmButtonTitle: "Reset Mailbox"
    )

    /// Shown when a confirmed reset could not back up the store, so nothing
    /// was deleted. Still offers the reset: the backup can fail for a reason
    /// that passes.
    static let mailboxResetFailedNotice = StoreLoadFailureNotice(
        title: "Couldn't Reset Your Mailbox",
        message: "MushMail couldn't make a backup of its mailbox, so nothing was deleted. Try again in a moment.",
        offersMailboxReset: true
    )

    static func storeLoadFailureKind(
        for error: Error,
        availableCapacityBytes: Int64?
    ) -> StoreLoadFailureKind {
        let isLowOnStorage = availableCapacityBytes.map { $0 < lowStorageThresholdBytes } ?? false
        let loadError = unwrappedLoadError(error)
        if isInsufficientStorage(loadError) || isLowOnStorage {
            return .insufficientStorage
        }
        if case PersistentStoreLoadError.unavailable = loadError {
            return .storeUnavailable
        }
        return .other
    }

    /// The count of consecutive failures toward `mailboxResetFailureThreshold`
    /// after one more failure of `kind`. A storage or unrecognized failure
    /// ends the streak. A failure while protected data is unavailable (a cold
    /// background launch before first unlock, or a locked device) neither
    /// counts nor ends it: data protection alone explains it, so it says
    /// nothing about the file.
    static func resetEligibleFailureCount(
        afterFailureOf kind: StoreLoadFailureKind,
        previousCount: Int,
        isProtectedDataAvailable: Bool
    ) -> Int {
        guard kind == .storeUnavailable else {
            return 0
        }
        return isProtectedDataAvailable ? previousCount + 1 : previousCount
    }

    static func storeLoadFailureNotice(
        for kind: StoreLoadFailureKind,
        resetEligibleFailureCount: Int
    ) -> StoreLoadFailureNotice {
        switch kind {
        case .insufficientStorage:
            return StoreLoadFailureNotice(
                title: "Not Enough Storage",
                message: "MushMail needs more free space to open your mail. Free up storage in Settings, then try again.",
                offersMailboxReset: false
            )
        case .storeUnavailable where resetEligibleFailureCount >= mailboxResetFailureThreshold:
            return StoreLoadFailureNotice(
                title: "Can't Open Your Mail",
                message: "MushMail still can't open its mailbox. If trying again doesn't help, you can reset it and download your mail again from Gmail.",
                offersMailboxReset: true
            )
        case .storeUnavailable, .other:
            return StoreLoadFailureNotice(
                title: "Can't Open Your Mail",
                message: "MushMail couldn't open its mailbox. Try again in a moment.",
                offersMailboxReset: false
            )
        }
    }

    private static func unwrappedLoadError(_ error: Error) -> Error {
        if case CoreDataError.storeLoadFailed(let underlying) = error {
            return underlying
        }
        return error
    }

    private static func isInsufficientStorage(_ loadError: Error) -> Bool {
        switch loadError {
        case PersistentStoreLoadError.insufficientStorage:
            return true
        case PersistentStoreLoadError.unavailable(let underlying):
            return StorageErrorClassifier.isOutOfSpace(underlying)
        default:
            return StorageErrorClassifier.isOutOfSpace(loadError)
        }
    }
}
