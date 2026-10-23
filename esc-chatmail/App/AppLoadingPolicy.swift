import Foundation

/// Decides what the launch screen says when the mailbox store could not be
/// opened. Every load failure that reaches the screen left the store latched
/// for a retry (`PersistentStoreLoadError`), so the screen always offers one.
enum AppLoadingPolicy {
    struct StoreLoadFailureNotice: Equatable {
        let title: String
        let message: String
    }

    /// Below this much free space an open failure is presented as a full
    /// device even when the error does not say so: at 0 bytes free SQLite
    /// reports SQLITE_CANTOPEN rather than SQLITE_FULL.
    static let lowStorageThresholdBytes: Int64 = 200 * 1024 * 1024

    static func storeLoadFailureNotice(
        for error: Error,
        availableCapacityBytes: Int64?
    ) -> StoreLoadFailureNotice {
        let isLowOnStorage = availableCapacityBytes.map { $0 < lowStorageThresholdBytes } ?? false
        if isInsufficientStorage(error) || isLowOnStorage {
            return StoreLoadFailureNotice(
                title: "Not Enough Storage",
                message: "MushMail needs more free space to open your mail. Free up storage in Settings, then try again."
            )
        }
        return StoreLoadFailureNotice(
            title: "Can't Open Your Mail",
            message: "MushMail couldn't open its mailbox. Try again in a moment."
        )
    }

    private static func isInsufficientStorage(_ error: Error) -> Bool {
        var loadError = error
        if case CoreDataError.storeLoadFailed(let underlying) = error {
            loadError = underlying
        }
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
