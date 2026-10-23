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
    /// or a reset or migration recovery whose backup could not be written.
    case unavailable(Error)

    init(classifying error: Error) {
        self = StorageErrorClassifier.isOutOfSpace(error)
            ? .insufficientStorage(error)
            : .unavailable(error)
    }

    var underlyingError: Error {
        switch self {
        case .insufficientStorage(let error), .unavailable(let error):
            return error
        }
    }

    var errorDescription: String? {
        switch self {
        case .insufficientStorage:
            return "There is not enough storage to open the mailbox"
        case .unavailable:
            return "The mailbox could not be opened"
        }
    }
}
