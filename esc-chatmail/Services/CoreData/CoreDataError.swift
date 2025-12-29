import Foundation

enum CoreDataError: LocalizedError {
    case storeLoadFailed(Error)
    case migrationFailed(Error)
    case saveFailed(Error)
    case transientFailure(Error)
    case persistentFailure(Error)
    case stackDestroyed

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
        }
    }

    var recoverySuggestion: String? {
        switch self {
        case .storeLoadFailed, .migrationFailed, .persistentFailure, .stackDestroyed:
            return "Please restart the app. If the problem persists, you may need to reinstall."
        case .saveFailed, .transientFailure:
            return "Please try again. Your data is safe."
        }
    }
}
