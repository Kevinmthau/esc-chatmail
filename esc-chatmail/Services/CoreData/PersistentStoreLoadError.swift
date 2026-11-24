import Foundation

/// The persistent store failed to open and was deliberately left on disk.
/// `CoreDataStack` latches this until `retryLoadAfterFailure()`; it never
/// means the user's data is gone.
enum PersistentStoreLoadError: LocalizedError {
    /// The volume is full (`StorageErrorClassifier.isOutOfSpace`). Freeing
    /// space and retrying can succeed.
    case insufficientStorage(Error)
    /// Anything else that did not end in a store reset: an I/O, permission or
    /// data-protection failure, an exhausted timeout, an unclassified error,
    /// a reset whose backup could not be written, or a migration-family error
    /// whose store's metadata could not be read.
    case unavailable(Error)
    /// A migration-family error on a store whose model is one this build
    /// bundles: the migration to this build's model failed on the user's data.
    /// Retrying may not help, so the user is offered Reset Mailbox once
    /// retrying has not (`AppLoadingPolicy`); nothing deletes it otherwise.
    case migrationFailed(Error)
    /// A migration-family error on a store whose model this build does not
    /// bundle: a newer MushMail saved it (a downgrade, or a development build
    /// sharing the Mac's container). Only a build that knows its model can
    /// open it, so nothing ever offers to reset it (Kevin, 2026-11-24).
    case storeFromNewerVersion(Error)

    init(classifying error: Error) {
        self = StorageErrorClassifier.isOutOfSpace(error)
            ? .insufficientStorage(error)
            : .unavailable(error)
    }

    var underlyingError: Error {
        switch self {
        case .insufficientStorage(let error), .unavailable(let error),
             .migrationFailed(let error), .storeFromNewerVersion(let error):
            return error
        }
    }

    var errorDescription: String? {
        switch self {
        case .insufficientStorage:
            return "There is not enough storage to open the mailbox"
        case .unavailable:
            return "The mailbox could not be opened"
        case .migrationFailed:
            return "The mailbox could not be updated for this version of MushMail"
        case .storeFromNewerVersion:
            return "The mailbox was saved by a newer version of MushMail"
        }
    }
}
