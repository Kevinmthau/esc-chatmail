import Foundation

enum CoreDataError: LocalizedError {
    case storeLoadFailed(Error)
    case migrationFailed(Error)
    case saveFailed(Error)
    case transientFailure(Error)
    case persistentFailure(Error)
    case stackDestroyed
    case entityCreationFailed(String)

    var errorDescription: String? {
        switch self {
        case .storeLoadFailed(let error):
            return "Failed to load data store: \(error.localizedDescription)"
        case .migrationFailed(let error):
            return "Failed to migrate data: \(error.localizedDescription)"
        case .saveFailed(let error):
            return "Failed to save data: \(error.localizedDescription)"
        case .transientFailure(let error):
            return "Temporary data error: \(error.localizedDescription)"
        case .persistentFailure(let error):
            return "Critical data error: \(error.localizedDescription)"
        case .stackDestroyed:
            return "Data stack has been destroyed"
        case .entityCreationFailed(let entityName):
            return "Failed to create entity: \(entityName)"
        }
    }

    /// The error this case wraps, if any. A Swift enum bridges to `NSError` without
    /// `NSUnderlyingErrorKey`, so `StorageErrorClassifier.errorChain` follows this instead: a sync
    /// page save that fails with `SQLITE_FULL` arrives as `.saveFailed` from `saveAsync`.
    var underlyingError: Error? {
        switch self {
        case .storeLoadFailed(let error), .migrationFailed(let error), .saveFailed(let error),
             .transientFailure(let error), .persistentFailure(let error):
            return error
        case .stackDestroyed, .entityCreationFailed:
            return nil
        }
    }

    var recoverySuggestion: String? {
        switch self {
        case .storeLoadFailed, .migrationFailed, .persistentFailure, .stackDestroyed, .entityCreationFailed:
            return "Please restart the app. If the problem persists, you may need to reinstall."
        case .saveFailed, .transientFailure:
            return "Please try again. Your data is safe."
        }
    }
}
