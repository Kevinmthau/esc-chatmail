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
///
/// A migration-family load error keeps the store too, and is offered the reset
/// in the same way as any other (Kevin, 2026-11-24): never deleted
/// automatically, and offered behind the confirmation once retrying has not
/// helped. A store a newer MushMail saved differs in its words alone: the
/// notice asks the user to update, and the confirmation says that updating
/// keeps the mailbox and the reset removes it.
enum AppLoadingPolicy {
    struct StoreLoadFailureNotice: Equatable {
        let title: String
        let message: String
        /// Shows Reset Mailbox beside Try Again.
        let offersMailboxReset: Bool
        /// What the confirmation behind Reset Mailbox says.
        var resetConfirmation: MailboxResetConfirmation = AppLoadingPolicy.mailboxResetConfirmation
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
        /// The migration to this build's model failed on the user's data
        /// (`PersistentStoreLoadError.migrationFailed`). The store is kept;
        /// once retrying has not helped, the user may reset it.
        case migrationFailed
        /// A newer MushMail saved the store
        /// (`PersistentStoreLoadError.storeFromNewerVersion`). Updating is the
        /// fix that keeps the mailbox; the reset is offered as for any other
        /// failure, in words that say so (Kevin, 2026-11-24).
        case storeFromNewerVersion
        /// Any other error. `CoreDataStack.resetStoreAfterLoadFailure()`
        /// refuses to reset these, so the screen does not offer it.
        case other
    }

    struct MailboxResetConfirmation: Equatable {
        let title: String
        let message: String
        let confirmButtonTitle: String
    }

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

    /// The confirmation for a mailbox a newer MushMail saved: updating opens
    /// it as it is, and the reset deletes it.
    static let newerVersionMailboxResetConfirmation = MailboxResetConfirmation(
        title: "Reset Mailbox?",
        message: "Updating MushMail keeps your mailbox on this device as it is. Resetting deletes it and downloads your mail again from Gmail; changes that haven't synced yet, drafts, and messages that haven't finished sending will be lost.",
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

    /// Below `StoreVolumeFreeSpace.lowStorageThresholdBytes` of free space
    /// an open failure is presented as a full device even when the error does
    /// not say so. `availableCapacityBytes` is a `StoreVolumeFreeSpace`
    /// reading.
    static func storeLoadFailureKind(
        for error: Error,
        availableCapacityBytes: Int64?
    ) -> StoreLoadFailureKind {
        let isLowOnStorage = availableCapacityBytes.map {
            $0 < StoreVolumeFreeSpace.lowStorageThresholdBytes
        } ?? false
        let loadError = unwrappedLoadError(error)
        if isInsufficientStorage(loadError) || isLowOnStorage {
            return .insufficientStorage
        }
        switch loadError {
        case PersistentStoreLoadError.unavailable:
            return .storeUnavailable
        case PersistentStoreLoadError.migrationFailed:
            return .migrationFailed
        case PersistentStoreLoadError.storeFromNewerVersion:
            return .storeFromNewerVersion
        default:
            return .other
        }
    }

    /// The count of consecutive failures toward `mailboxResetFailureThreshold`
    /// after one more failure of `kind`. Only the kinds a reset is offered for
    /// count (`offersResetPastThreshold`); a storage or unrecognized failure
    /// ends the streak. A failure while protected data is unavailable (a cold
    /// background launch before first unlock, or a locked device) neither
    /// counts nor ends it: data protection alone explains it, so it says
    /// nothing about the file. Nor does one whose free space could not be
    /// measured: a full disk may explain it, and
    /// `CoreDataStack.resetStoreAfterLoadFailure()` refuses to reset without
    /// a reading, so counting it would offer a reset that cannot run (and
    /// `storeLoadFailureNotice` withholds an offer already earned).
    static func resetEligibleFailureCount(
        afterFailureOf kind: StoreLoadFailureKind,
        previousCount: Int,
        isProtectedDataAvailable: Bool,
        isFreeSpaceKnown: Bool
    ) -> Int {
        guard offersResetPastThreshold(kind) else {
            return 0
        }
        return isProtectedDataAvailable && isFreeSpaceKnown ? previousCount + 1 : previousCount
    }

    /// Offers Reset Mailbox only from `mailboxResetFailureThreshold` counted
    /// failures and only when this failure's free space could be measured. A
    /// failure without a reading keeps the streak, so an offer earned earlier
    /// would otherwise stay on screen while
    /// `CoreDataStack.resetStoreAfterLoadFailure()` refuses every reset, and
    /// confirming the data loss would only retry. The offer returns with the
    /// next failure that has a reading.
    static func storeLoadFailureNotice(
        for kind: StoreLoadFailureKind,
        resetEligibleFailureCount: Int,
        isFreeSpaceKnown: Bool
    ) -> StoreLoadFailureNotice {
        switch kind {
        case .insufficientStorage:
            return StoreLoadFailureNotice(
                title: "Not Enough Storage",
                message: "MushMail needs more free space to open your mail. Free up storage in Settings, then try again.",
                offersMailboxReset: false
            )
        case .storeFromNewerVersion where isFreeSpaceKnown && resetEligibleFailureCount >= mailboxResetFailureThreshold:
            return StoreLoadFailureNotice(
                title: "Update MushMail",
                message: "Your mailbox on this device was saved by a newer version of MushMail. Update MushMail to open it, or reset the mailbox and download your mail again from Gmail.",
                offersMailboxReset: true,
                resetConfirmation: newerVersionMailboxResetConfirmation
            )
        case .storeFromNewerVersion:
            return StoreLoadFailureNotice(
                title: "Update MushMail",
                message: "Your mailbox on this device was saved by a newer version of MushMail. Update MushMail to open it.",
                offersMailboxReset: false,
                resetConfirmation: newerVersionMailboxResetConfirmation
            )
        case .migrationFailed where isFreeSpaceKnown && resetEligibleFailureCount >= mailboxResetFailureThreshold:
            return StoreLoadFailureNotice(
                title: "Can't Open Your Mail",
                message: "MushMail still can't update its mailbox for this version. If trying again doesn't help, you can reset it and download your mail again from Gmail.",
                offersMailboxReset: true
            )
        case .migrationFailed:
            return StoreLoadFailureNotice(
                title: "Can't Open Your Mail",
                message: "MushMail couldn't update its mailbox for this version. Tap Try Again to try once more.",
                offersMailboxReset: false
            )
        case .storeUnavailable where isFreeSpaceKnown && resetEligibleFailureCount >= mailboxResetFailureThreshold:
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

    /// The kinds Reset Mailbox is offered for once
    /// `mailboxResetFailureThreshold` failures have counted. The same set
    /// `CoreDataStack.allowsResetAfterLoadFailure` accepts.
    static func offersResetPastThreshold(_ kind: StoreLoadFailureKind) -> Bool {
        switch kind {
        case .storeUnavailable, .migrationFailed, .storeFromNewerVersion:
            return true
        case .insufficientStorage, .other:
            return false
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
