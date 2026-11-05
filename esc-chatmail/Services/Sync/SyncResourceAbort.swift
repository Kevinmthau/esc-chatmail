import Foundation

/// A device-wide condition that stops a sync run, like an account-scoped API abort
/// (`APIError.isAccountScopedSyncAbort`): it proves nothing about any message, so no ID goes into a
/// failure bucket, no request follows it, and it is rethrown so nothing the run staged commits.
/// Recording it per message would spend the escape hatch on mail that was never at fault.
enum SyncResourceAbort: LocalizedError, Equatable {
    /// The volume is full, or too close to full to start a run. Every write would fail the same
    /// way, so retrying sooner than the backoff only re-fetches the same backlog.
    case insufficientStorage

    var errorDescription: String? {
        switch self {
        case .insufficientStorage:
            return "Not enough storage to sync new mail. Free up space on this iPhone."
        }
    }

    /// True for a run stopped by a full disk: this abort itself, or a write the volume refused
    /// anywhere in the error's chain, such as a Core Data save failing with `SQLITE_FULL`.
    static func isInsufficientStorage(_ error: Error) -> Bool {
        if let abort = error as? SyncResourceAbort, abort == .insufficientStorage {
            return true
        }
        return StorageErrorClassifier.isOutOfSpace(error)
    }
}
